# frozen_string_literal: true

require 'uri'

module DebugBundle
  module Rack
    class Middleware
      def initialize(app, client: DebugBundle.client)
        @app = app
        @client = client
      end

      def call(env)
        request_context = build_request_context(env)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @client.with_request_trigger(request_context.fetch(:request)) do
          status, headers, body = @app.call(env)
          duration_ms = elapsed_ms(started_at)

          @client.capture_request(
            request_context.fetch(:request),
            { status_code: status, headers: headers.to_h },
            context: request_context.merge(duration_ms: duration_ms, route_template: route_template(env))
          )

          [status, headers, body]
        end
      rescue StandardError => e
        duration_ms = elapsed_ms(started_at)
        @client.capture_exception(
          e,
          context: request_context.merge(
            response: { status_code: 500, headers: {} },
            duration_ms: duration_ms,
            route_template: route_template(env)
          ),
          handled: false
        )
        raise
      end

      private

      def build_request_context(env)
        {
          request: {
            method: env['REQUEST_METHOD'],
            path: env['PATH_INFO'],
            query: parse_query(env['QUERY_STRING']),
            headers: request_headers(env),
            body: {}
          },
          request_id: env['action_dispatch.request_id'] || env['HTTP_X_REQUEST_ID'],
          trace_id: env['HTTP_X_DEBUGBUNDLE_TRACE_ID']
        }.merge(rails_metadata(env))
      end

      def request_headers(env)
        env.each_with_object({}) do |(key, value), headers|
          next unless key.start_with?('HTTP_') || %w[CONTENT_TYPE ACCEPT].include?(key)

          normalized_key = key.sub(/^HTTP_/, '').downcase.tr('_', '-')
          headers[normalized_key] = value
        end
      end

      def parse_query(query_string)
        raw_query = query_string.to_s
        return {} if raw_query.bytesize > 16_384

        URI.decode_www_form(raw_query.tr(';', '&')).each_with_object({}) do |(key, value), result|
          result[key] = if result.key?(key)
                          Array(result[key]) << value
                        else
                          value
                        end
        end
      rescue StandardError
        # Broken request metadata must never interrupt the host application.
        {}
      end

      def route_template(env)
        env['debugbundle.route_template'] || env['action_dispatch.route_uri_pattern']
      end

      def rails_metadata(env)
        parameters = env['action_dispatch.request.parameters'] || {}
        metadata = {}
        if env.key?('action_dispatch.request_id') || env.key?('action_dispatch.route_uri_pattern')
          metadata[:framework] = 'rails'
        end
        metadata[:route_template] = route_template(env) if route_template(env)
        metadata[:controller] = parameters['controller'] if parameters['controller']
        metadata[:action] = parameters['action'] if parameters['action']
        metadata
      end

      def elapsed_ms(started_at)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      end
    end
  end
end
