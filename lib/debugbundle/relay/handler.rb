# frozen_string_literal: true

require 'json'
require 'uri'

module DebugBundle
  module Relay
    ACCEPTED_EVENT_TYPES = %w[
      frontend_exception
      error_suppressed
      frontend_breadcrumb
      request_event
      probe_event
    ].freeze
    BROWSER_SDK_NAME = '@debugbundle/sdk-browser'
    DEFAULT_MAX_BODY_BYTES = 262_144
    DEFAULT_RATE_LIMIT_PER_MINUTE = 60

    Response = Struct.new(:status, :body, keyword_init: true)

    class Handler
      def initialize(
        project_mode: :connected,
        project_token: nil,
        endpoint: DebugBundle::Config::DEFAULT_ENDPOINT,
        local_events_dir: DebugBundle::Config::DEFAULT_LOCAL_EVENTS_DIR,
        spool_dir: DebugBundle::Config::DEFAULT_SPOOL_DIR,
        durable_write: true,
        service: nil,
        environment: nil,
        allowed_origins: nil,
        max_body_bytes: DEFAULT_MAX_BODY_BYTES,
        rate_limit_per_minute: DEFAULT_RATE_LIMIT_PER_MINUTE,
        rate_limit_store: nil,
        forward_transport: nil
      )
        @project_mode = project_mode.to_sym
        @project_token = project_token
        @endpoint = endpoint
        @local_events_dir = local_events_dir
        @spool_dir = spool_dir
        @durable_write = durable_write
        @service = service
        @environment = environment
        @allowed_origins = Array(allowed_origins).compact.map { |origin| normalize_origin(origin) }
        @max_body_bytes = max_body_bytes
        @rate_limit_per_minute = rate_limit_per_minute
        @rate_limit_store = rate_limit_store
        @forward_transport = forward_transport || Transport::HttpTransport.new(@endpoint)
        @rate_limit_state = Hash.new { |hash, key| hash[key] = [] }
      end

      def handle(request)
        return Response.new(status: 405, body: nil) unless request.fetch(:method, 'POST').to_s.upcase == 'POST'

        headers = normalize_headers(request[:headers] || {})
        return Response.new(status: 403, body: nil) unless origin_allowed?(headers)
        unless json_content_type?(headers['content-type'])
          return Response.new(status: 400,
                              body: invalid_body('Relay requests must use Content-Type: application/json.'))
        end

        raw_body = request[:body].to_s
        return Response.new(status: 413, body: nil) if raw_body.bytesize > @max_body_bytes
        return Response.new(status: 429, body: nil) if rate_limited?(request[:ip_address] || request[:ip])

        decoded = JSON.parse(raw_body)
        batch = decoded.fetch('batch')
        unless batch.is_a?(Array)
          return Response.new(status: 400,
                              body: invalid_body('Relay request body must include a batch array.'))
        end

        accepted = []
        errors = []

        batch.each_with_index do |candidate, index|
          sanitized = sanitize_event(candidate)
          if sanitized
            accepted << sanitized
          else
            errors << "batch[#{index}]: Invalid browser relay event payload."
          end
        end

        deliver(accepted) unless accepted.empty?

        unless errors.empty?
          return Response.new(status: 400,
                              body: { 'accepted' => accepted.length,
                                      'rejected' => errors.length, 'errors' => errors })
        end

        Response.new(status: 202, body: { 'accepted' => accepted.length, 'rejected' => 0, 'errors' => [] })
      rescue JSON::ParserError
        Response.new(status: 400, body: invalid_body('Relay request body must be valid JSON.'))
      rescue KeyError
        Response.new(status: 400, body: invalid_body('Relay request body must include a batch array.'))
      rescue StandardError
        Response.new(status: 500, body: nil)
      end

      private

      def deliver(events)
        service_name = @service || events.first.dig('service', 'name') || 'service'

        case @project_mode
        when :local_only
          Transport::FileTransport.new(@local_events_dir).call(service_name: service_name, events: events)
        when :connected
          Transport::FileTransport.new(@spool_dir).call(service_name: service_name, events: events) if @durable_write

          result = Transport.coerce_result(@forward_transport.call(project_token: @project_token, events: events))
          raise 'relay_forward_failed' unless result.status_code.between?(200, 299)
        else
          raise ArgumentError, 'unsupported relay project mode'
        end
      end

      def sanitize_event(candidate)
        return nil unless candidate.is_a?(Hash)

        event_type = candidate['event_type']
        return nil unless ACCEPTED_EVENT_TYPES.include?(event_type)

        service = candidate['service']
        correlation = candidate['correlation']
        payload = candidate['payload']
        return nil unless service.is_a?(Hash) && payload.is_a?(Hash)

        {
          'schema_version' => candidate['schema_version'].to_s,
          'event_id' => candidate['event_id'].to_s,
          'event_type' => event_type,
          'sdk_name' => BROWSER_SDK_NAME,
          'sdk_version' => candidate['sdk_version'].to_s,
          'occurred_at' => candidate['occurred_at'].to_s,
          'service' => {
            'name' => @service || service['name'].to_s,
            'environment' => @environment || service['environment'].to_s
          },
          'correlation' => sanitize_correlation(correlation),
          'payload' => payload,
          'project_token' => @project_token
        }
      end

      def sanitize_correlation(value)
        correlation = value.is_a?(Hash) ? value : {}
        {
          'request_id' => string_or_nil(correlation['request_id']),
          'trace_id' => string_or_nil(correlation['trace_id']),
          'session_id' => string_or_nil(correlation['session_id']),
          'user_id_hash' => string_or_nil(correlation['user_id_hash'])
        }
      end

      def string_or_nil(value)
        value.is_a?(String) ? value : nil
      end

      def invalid_body(message)
        { 'accepted' => 0, 'rejected' => 0, 'errors' => [message] }
      end

      def normalize_headers(headers)
        headers.each_with_object({}) do |(key, value), result|
          result[key.to_s.downcase] = value.to_s
        end
      end

      def json_content_type?(value)
        value.to_s.downcase.include?('application/json')
      end

      def origin_allowed?(headers)
        origin = headers['origin'] || origin_from_referer(headers['referer'])
        return false if origin.nil? || origin.empty?

        return @allowed_origins.include?(normalize_origin(origin)) if @allowed_origins.any?

        host = headers['host'].to_s.split(':').first
        return false if host.empty?

        URI.parse(origin).host == host
      rescue URI::InvalidURIError
        false
      end

      def origin_from_referer(referer)
        return nil if referer.to_s.empty?

        parsed = URI.parse(referer)
        return nil unless parsed.scheme && parsed.host

        "#{parsed.scheme}://#{parsed.host}"
      rescue URI::InvalidURIError
        nil
      end

      def normalize_origin(origin)
        origin.to_s.downcase.sub(%r{/$}, '')
      end

      def rate_limited?(ip)
        key = ip.to_s.empty? ? 'unknown' : ip.to_s
        return shared_rate_limited?(key) if @rate_limit_store

        cutoff = Time.now.to_i - 60
        @rate_limit_state[key] = @rate_limit_state[key].select { |entry| entry > cutoff }
        return true if @rate_limit_state[key].length >= @rate_limit_per_minute

        @rate_limit_state[key] << Time.now.to_i
        false
      end

      def shared_rate_limited?(key)
        cache_key = "debugbundle:relay-rate:#{key}:#{Time.now.to_i / 60}"
        count = @rate_limit_store.increment(cache_key, 1, expires_in: 60)
        if count.nil? && @rate_limit_store.respond_to?(:write)
          @rate_limit_store.write(cache_key, 1, expires_in: 60)
          count = 1
        end
        count.to_i > @rate_limit_per_minute
      rescue StandardError
        false
      end
    end
  end
end
