# frozen_string_literal: true

require 'digest'
require 'time'
require 'uri'

require 'debugbundle/client_event_support'
require 'debugbundle/runtime'

module DebugBundle
  class Client
    SCHEMA_VERSION = '2026-03-01'
    SDK_NAME = '@debugbundle/sdk-ruby'
    DEFAULT_SERVICE_NAME = 'ruby-service'
    DEFAULT_ENVIRONMENT = 'development'
    MAX_BUFFER_SIZE = 1_000
    RETRY_AFTER_CAP_SECONDS = 300
    DEFAULT_HEADER_ALLOWLIST = %w[
      user-agent
      content-type
      accept
      x-request-id
      x-correlation-id
      x-debugbundle-trace-id
    ].freeze
    BALANCED_IMMEDIATE_REQUEST_STATUSES = [408, 423, 424, 425, 429].freeze
    INVESTIGATIVE_IMMEDIATE_REQUEST_STATUSES = (BALANCED_IMMEDIATE_REQUEST_STATUSES + [409]).freeze
    LOCAL_ENVIRONMENTS = %w[development local test].freeze
    REQUEST_TRIGGER_DIRECTIVES_KEY = :__debugbundle_request_trigger_directives__
    THREAD_HOOK_MUTEX = Mutex.new
    LOG_LEVEL_RANKS = {
      debug: 10,
      info: 20,
      warning: 30,
      error: 40,
      fatal: 50,
      critical: 50
    }.freeze

    attr_reader :config, :last_event_at

    class << self
      attr_accessor :thread_exception_client

      def dispatch_thread_exception(error) = thread_exception_client&.__send__(:capture_thread_exception, error)

      def install_thread_exception_hook!
        THREAD_HOOK_MUTEX.synchronize do
          return if @thread_exception_hook_installed

          interceptor = Module.new do
            define_method(:new) do |*args, &block|
              super(*args, &DebugBundle::Client.wrap_thread_block(block))
            end

            define_method(:start) do |*args, &block|
              super(*args, &DebugBundle::Client.wrap_thread_block(block))
            end

            define_method(:fork) do |*args, &block|
              super(*args, &DebugBundle::Client.wrap_thread_block(block))
            end
          end

          ::Thread.singleton_class.prepend(interceptor)
          @thread_exception_hook_installed = true
        end
      end

      def wrap_thread_block(block)
        return nil unless block

        proc do |*thread_args|
          block.call(*thread_args)
        rescue StandardError => e
          dispatch_thread_exception(e)
          raise
        end
      end
    end

    def initialize(transport: nil, time_provider: nil, random_provider: nil, config_fetcher: nil, **options)
      @config = Config.new(**options)
      @time_provider = time_provider || -> { Time.now.utc }
      @random_provider = random_provider || -> { rand }
      @redactor = Redaction::Redactor.new(
        sensitive_fields: Redaction::DEFAULT_SENSITIVE_FIELDS + config.redact_fields
      )
      @transport = transport || build_default_transport
      @config_fetcher = config_fetcher || build_default_config_fetcher(custom_transport: !transport.nil?)
      @context = {}
      @buffer = []
      @buffer_mutex = Mutex.new
      @flush_mutex = Mutex.new
      @probe_buffers = {}
      @suppression = Suppression::Tracker.new
      @last_event_at = nil
      @retry_at = nil
      @consecutive_failures = 0
      @acknowledgement_state = nil
      @at_exit_registered = false
      @thread_exception_registered = false
      @logger_bindings = {}
      @capture_semantic_logger = nil
      @next_remote_config_poll_at = nil
      @remote_config_etag = nil
      @remote_config = RemoteConfig::Snapshot.default
      @capture_policy = @remote_config.capture_policy

      refresh_remote_config!
      @capture_policy = RemoteConfig.minimal_capture_policy if @config_fetcher && @remote_config_etag.nil?
    end

    def capture_exception(error, context: nil, handled: true)
      capture_exception_internal(error, context: context, handled: handled, run_before_send: true)
    end

    def capture_exception_internal(error, context:, handled:, run_before_send:)
      return unless capture_enabled?

      poll_remote_config_if_due!

      merged_context = merge_context(context)
      payload = {
        'name' => error.class.name,
        'message' => error.message.to_s,
        'stack' => Array(error.backtrace).join("\n"),
        'handled' => handled,
        'request' => request_payload(merged_context['request']),
        'response' => response_payload(merged_context['response']),
        'runtime' => runtime_payload
      }

      causes = exception_causes(error)

      probe_data = probe_snapshot
      payload['probe_data'] = probe_data unless probe_data.empty?

      extra_context = merged_context.except('request', 'response', 'correlation')
      extra_context['causes'] = causes unless causes.empty?

      event = base_event('backend_exception', payload, extra_context)
      event = apply_before_send(event) if run_before_send
      return if event.nil?

      event_payload = event.fetch('payload')
      suppression_key = [
        event['event_type'],
        event_payload['name'],
        event_payload['message'],
        event_payload['stack']
      ].join(':')
      return unless @suppression.should_capture(suppression_key, now: monotonic_now)

      enqueue_event(event)
    end
    private :capture_exception_internal

    def capture_error(error, context: nil, handled: true) = capture_exception(error, context: context, handled: handled)

    def capture_log(message, level: :warning, context: nil)
      return unless capture_enabled?

      poll_remote_config_if_due!

      normalized_level = normalize_level(level || :warning)

      merged_context = merge_context(context)
      payload = {
        'level' => normalized_level.to_s,
        'message' => message.to_s,
        'attributes' => merged_context
      }
      event = apply_before_send(base_event('log_event', payload, merged_context))
      return if event.nil? || !level_enabled?(normalized_level)

      enqueue_event(event)
    end

    def capture_request(request, response, context: nil)
      return unless capture_enabled?

      poll_remote_config_if_due!

      merged_context = merge_context(context)
      sanitized_request = request_payload(request)
      sanitized_response = response_payload(response)
      response_status = (sanitized_response['status_code'] || 0).to_i

      payload = {
        'method' => sanitized_request['method'],
        'path' => sanitized_request['path'],
        'query' => sanitized_request['query'],
        'headers' => sanitized_request['headers'],
        'body' => sanitized_request['body'],
        'response_status' => response_status,
        'duration_ms' => extract_duration_ms(merged_context, sanitized_response),
        'route_template' => merged_context['route_template'],
        'response_headers' => sanitized_response['headers'],
        'response_body' => sanitized_response['body']
      }
      event = apply_before_send(
        base_event('request_event', payload, merged_context.merge('request' => sanitized_request))
      )
      return if event.nil? || !capture_request_event?(response_status, sanitized_request)

      enqueue_event(event)
    end

    def capture_message(message, level: nil, context: nil)
      capture_log(message, level: level || :info, context: context)
    end

    def set_context(key, value)
      @context[key.to_s] = @redactor.redact_value(value)
      value
    end

    def probe(label, data = nil, heavy: false, &block)
      return unless capture_enabled?

      poll_remote_config_if_due!
      return unless @remote_config.probes_enabled

      matching_directives = matching_probe_directives(label)
      if heavy
        return if matching_directives.empty?

        resolved, raw_value = resolve_probe_value(data, block)
        return unless resolved

        emit_probe_events(label.to_s, normalize_probe_data(raw_value), matching_directives)
        return
      end

      return if !@probe_buffers.key?(label) && @probe_buffers.size >= config.max_probe_labels

      resolved, raw_value = resolve_probe_value(data, block)
      return unless resolved

      entry = {
        'label' => label.to_s,
        'data' => normalize_probe_data(raw_value),
        'timestamp' => now.iso8601
      }

      bucket = (@probe_buffers[label.to_s] ||= [])
      bucket << entry
      bucket.shift while bucket.length > config.max_probe_entries_per_label

      emit_probe_events(label.to_s, entry['data'], matching_directives)
    end

    def capture_exceptions
      at_exit_registered = capture_at_exit
      thread_registered = capture_thread_exceptions

      at_exit_registered || thread_registered
    end

    def capture_at_exit
      return false if @at_exit_registered

      @at_exit_registered = true
      client = self
      at_exit do
        error = $ERROR_INFO
        next unless error.is_a?(Exception)

        client.__send__(
          :capture_exception_internal,
          error,
          context: nil,
          handled: false,
          run_before_send: false
        )
        client.flush
      end
      true
    end

    def capture_logger(logger = ::Logger.new($stdout))
      binding_key = logger.object_id
      return logger if @logger_bindings.key?(binding_key)

      @logger_bindings[binding_key] = Logging.install_stdlib_logger(logger, client: self)
      logger
    end

    def capture_semantic_logger
      @capture_semantic_logger ||= Logging.install_semantic_logger(client: self)
    end

    def with_request_trigger(request)
      poll_remote_config_if_due! if capture_enabled?

      directives = TriggerToken.resolve_request_directives(
        request: request,
        trigger_token_key: @remote_config.trigger_token_key
      )
      previous = Thread.current[REQUEST_TRIGGER_DIRECTIVES_KEY]
      Thread.current[REQUEST_TRIGGER_DIRECTIVES_KEY] = directives
      yield
    ensure
      Thread.current[REQUEST_TRIGGER_DIRECTIVES_KEY] = previous
    end

    def refresh_remote_config!
      return false unless capture_enabled?
      return false unless @config_fetcher

      response = @config_fetcher.call(@remote_config_etag)
      status_code = response.fetch(:status_code, 500)
      if status_code == 304
        schedule_next_remote_config_poll
        return true
      end
      unless status_code == 200
        schedule_next_remote_config_poll
        return false
      end

      snapshot = RemoteConfig.parse(response.fetch(:body, {}), config.probes_poll_interval)
      unless snapshot
        schedule_next_remote_config_poll
        return false
      end

      @remote_config = snapshot
      @capture_policy = snapshot.capture_policy
      @remote_config_etag = response[:etag]
      schedule_next_remote_config_poll
      true
    rescue StandardError
      schedule_next_remote_config_poll
      false
    end

    def with_exception_capture(context: nil)
      yield
    rescue StandardError => e
      capture_exception(e, context: context, handled: false)
      raise
    end

    def flush
      # rubocop:disable Metrics/BlockLength
      @flush_mutex.synchronize do
        append_suppression_aggregates
        batch = buffered_batch
        return true if batch.empty?
        return false if @transport.nil?
        return false if rate_limited?

        result = Transport.coerce_result(
          @transport.call(
            project_token: config.project_token,
            service_name: service_name,
            events: batch.map(&:dup)
          )
        )

        case result.status_code
        when 200..299
          handle_successful_result(result, batch)
        when 429
          @consecutive_failures += 1
          retry_after_seconds = (result.retry_after_seconds || 1).clamp(1, RETRY_AFTER_CAP_SECONDS)
          @retry_at = now + retry_after_seconds
          false
        when 400..499
          remove_buffered_events(batch)
          @retry_at = nil
          @consecutive_failures = 0
          false
        else
          @consecutive_failures += 1
          false
        end
      end
      # rubocop:enable Metrics/BlockLength
    rescue StandardError
      @consecutive_failures += 1
      false
    end

    def status
      return :disconnected unless config.enabled?
      return :degraded unless config.configured?
      return @acknowledgement_state if @acknowledgement_state
      return :disconnected if @consecutive_failures >= 3
      return :degraded if rate_limited?

      :healthy
    end

    def buffered_event_count = @buffer_mutex.synchronize { @buffer.length }

    private

    def handle_successful_result(result, batch)
      decision = Acknowledgement.decide(result.body, batch.length)
      return handle_protocol_failure if decision[:kind] == :protocol_failure

      if decision[:kind] == :legacy
        remove_buffered_events(batch)
        record_success
        return true
      end

      retryable_indices = decision.fetch(:retryable_indices)
      retryable_events = retryable_indices.map { |index| batch.fetch(index) }
      remove_buffered_events(batch - retryable_events)
      @last_event_at = now if decision.fetch(:accepted).positive?

      if retryable_events.any?
        @consecutive_failures += 1
        @retry_at = now + 1
        @acknowledgement_state = :degraded
        false
      else
        @retry_at = nil
        @consecutive_failures = 0
        @acknowledgement_state = decision.fetch(:accepted).positive? ? nil : :disconnected
        decision.fetch(:accepted).positive?
      end
    end

    def handle_protocol_failure
      @consecutive_failures += 1
      @retry_at = now + 1
      @acknowledgement_state = :degraded
      false
    end

    def record_success
      @retry_at = nil
      @consecutive_failures = 0
      @acknowledgement_state = nil
      @last_event_at = now
    end

    def build_default_transport
      return nil unless config.enabled?

      if config.project_mode == :local_only || local_environment?
        Transport::FileTransport.new(config.local_events_dir)
      elsif config.configured?
        Transport::HttpTransport.new(config.endpoint)
      end
    end

    def build_default_config_fetcher(custom_transport:)
      return nil if custom_transport
      return nil unless config.enabled? && config.configured?
      return nil if config.project_mode == :local_only || local_environment?

      Transport::HttpConfigFetcher.new(
        config.endpoint,
        project_token: config.project_token,
        sdk_name: SDK_NAME,
        sdk_version: DebugBundle::VERSION
      )
    end

    def capture_request_event?(status_code, request)
      mode = @capture_policy.capture_request_events

      return true if mode == 'all'
      return true if immediate_request_event?(status_code, request)
      return true if mode == 'failures_only' && status_code >= 500

      false
    end

    def immediate_request_event?(status_code, request)
      return true if status_code >= 500
      return true if immediate_request_statuses.include?(status_code)
      return true if matching_immediate_client_error_path_rule?(status_code, request)

      false
    end

    def immediate_request_statuses
      statuses = case @capture_policy.preset
                 when 'minimal'
                   []
                 when 'investigative'
                   INVESTIGATIVE_IMMEDIATE_REQUEST_STATUSES
                 else
                   BALANCED_IMMEDIATE_REQUEST_STATUSES
                 end

      statuses + Array(@capture_policy.immediate_client_error_statuses)
    end

    def matching_immediate_client_error_path_rule?(status_code, request)
      return false unless (400..499).cover?(status_code)

      path = normalize_request_path(request['path'] || request['url'])
      method = request['method'].to_s.upcase
      Array(@capture_policy.immediate_client_error_path_rules).any? do |rule|
        next false unless rule.status_code == status_code
        next false if !rule.http_methods.empty? && !rule.http_methods.include?(method)

        if rule.path_pattern.end_with?('*')
          path.start_with?(rule.path_pattern.delete_suffix('*'))
        else
          path == rule.path_pattern
        end
      end
    end

    def normalize_request_path(value)
      begin
        uri = URI.parse(value.to_s)
        return uri.path if uri.path && !uri.path.empty?
      rescue URI::InvalidURIError
        # Fall through to the lightweight path-only fallback.
      end
      fallback = value.to_s.split('?', 2).first.to_s.split('#', 2).first
      return fallback if fallback.start_with?('/') && !fallback.empty?

      '/'
    end

    def matching_probe_directives(label)
      active_directives = @remote_config.directives + current_request_trigger_directives

      active_directives.select do |directive|
        directive.active?(label: label.to_s, service: service_name, environment: environment_name, now: now)
      end
    end

    def current_request_trigger_directives = Array(Thread.current[REQUEST_TRIGGER_DIRECTIVES_KEY])

    def matching_request_trigger_directives(label)
      current_request_trigger_directives.select do |directive|
        directive.active?(label: label.to_s, service: service_name, environment: environment_name, now: now)
      end
    end

    def emit_probe_events(label, data, matching_directives)
      request_directives = matching_request_trigger_directives(label)
      candidate_directives = (matching_directives + request_directives).uniq(&:id)
      return if candidate_directives.empty?

      candidate_directives.each do |directive|
        event = apply_before_send(
          base_event(
            'probe_event',
            {
              'label' => label,
              'data' => data,
              'activation_id' => directive.id,
              'probe_label_pattern' => directive.label_pattern
            },
            {}
          )
        )
        allowed = request_directives.include?(directive) ||
                  @capture_policy.capture_probe_events == 'standalone_when_activated'
        enqueue_event(event) if event && allowed
      end
    end

    def extract_duration_ms(context, response)
      duration = context['duration_ms'] || response['duration_ms']
      return duration.to_i if duration

      0
    end

    def rate_limited? = @retry_at && @retry_at > now

    def local_environment? = LOCAL_ENVIRONMENTS.include?(environment_name.to_s)

    def poll_remote_config_if_due!
      return unless @config_fetcher
      return unless @next_remote_config_poll_at && @next_remote_config_poll_at <= now

      refresh_remote_config!
    end

    def schedule_next_remote_config_poll
      interval_seconds = if @remote_config.remote_probes_enabled
                           @remote_config.poll_interval_seconds
                         elsif @remote_config_etag.nil?
                           config.probes_poll_interval
                         end

      @next_remote_config_poll_at = interval_seconds ? now + interval_seconds : nil
    end

    def capture_thread_exceptions
      return false if @thread_exception_registered

      self.class.thread_exception_client = self
      Thread.report_on_exception = true if Thread.respond_to?(:report_on_exception=)
      self.class.install_thread_exception_hook!
      @thread_exception_registered = true
      true
    end

    def capture_thread_exception(error)
      capture_exception_internal(error, context: nil, handled: false, run_before_send: false)
      flush
    rescue StandardError
      nil
    end

    def now = @time_provider.call

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
