# frozen_string_literal: true

module DebugBundle
  class Client
    module EventSupport
      private

      def capture_enabled? = config.enabled? && config.configured?

      def merge_context(context)
        merged = @context.merge(stringify_hash(context || {}))
        @redactor.redact_value(merged)
      end

      def stringify_hash(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, nested_value), result|
          result[key.to_s] = nested_value
        end
      end

      def request_payload(request)
        source = object_to_hash(request)
        {
          'method' => source['method'] || 'UNKNOWN',
          'path' => source['path'] || '/',
          'query' => @redactor.redact_value(source['query'] || {}),
          'headers' => sanitized_headers(source['headers'] || {}),
          'body' => @redactor.redact_value(source['body'] || {})
        }
      end

      def response_payload(response)
        source = object_to_hash(response)
        {
          'status_code' => source['status_code'] || source['status'] || 0,
          'headers' => sanitized_headers(source['headers'] || {}),
          'body' => @redactor.redact_value(source['body'] || {})
        }
      end

      def runtime_payload = Runtime.payload

      def exception_causes(error)
        causes = []
        current = error.cause

        while current
          causes << {
            'name' => current.class.name,
            'message' => current.message.to_s,
            'stack' => Array(current.backtrace).join("\n")
          }
          current = current.cause
        end

        causes
      end

      def probe_snapshot
        items = @probe_buffers.values.flatten.map do |entry|
          entry.merge('activation_id' => nil)
        end
        return {} if items.empty?

        { 'version' => 1, 'items' => items }
      end

      def resolve_probe_value(data, block)
        [true, block ? block.call : data]
      rescue StandardError
        [false, nil]
      end

      def normalize_probe_data(value)
        redacted = @redactor.redact_value(value)
        redacted.is_a?(Hash) ? redacted : { 'value' => redacted }
      end

      def apply_before_send(event)
        BeforeSend.apply(event, config.before_send)
      end

      def enqueue_event(event)
        return unless sampled_in?

        @buffer_mutex.synchronize do
          @buffer << event
          @buffer.shift while @buffer.length > MAX_BUFFER_SIZE
        end
      end

      def buffered_batch
        @buffer_mutex.synchronize { @buffer.dup }
      end

      def remove_buffered_events(events)
        event_ids = events.map { |event| event['event_id'] }
        @buffer_mutex.synchronize do
          @buffer.reject! { |event| event_ids.include?(event['event_id']) }
        end
      end

      def sampled_in?
        return false if config.sample_rate <= 0.0
        return true if config.sample_rate >= 1.0

        @random_provider.call.to_f < config.sample_rate
      rescue StandardError
        true
      end

      def append_suppression_aggregates
        @suppression.drain_aggregates(now: monotonic_now).each do |aggregate|
          event = apply_before_send(base_event('error_suppressed', aggregate, {}))
          enqueue_event(event) if event
        end
      end

      def base_event(event_type, payload, context)
        redacted_payload = @redactor.redact_value(payload)
        preserve_redacted_probe_data!(event_type, payload, redacted_payload)
        event = {
          'schema_version' => SCHEMA_VERSION,
          'event_id' => SecureRandom.uuid,
          'event_type' => event_type,
          'project_token' => config.project_token,
          'sdk_name' => SDK_NAME,
          'sdk_version' => DebugBundle::VERSION,
          'service' => {
            'name' => service_name,
            'runtime' => 'ruby',
            'framework' => context['framework'],
            'environment' => environment_name
          },
          'occurred_at' => now.iso8601,
          'correlation' => correlation_payload(context),
          'payload' => redacted_payload
        }
        envelope_context = event_context(context)
        event['context'] = envelope_context unless envelope_context.empty?
        event
      end

      # Probe values are redacted before entering the in-memory probe buffer. Re-running
      # the depth limiter after nesting them inside an event would replace valid scalar
      # and list values with truncation markers.
      def preserve_redacted_probe_data!(event_type, payload, redacted_payload)
        if event_type == 'backend_exception' && payload.key?('probe_data')
          preserve_probe_snapshot_values!(payload, redacted_payload)
        elsif event_type == 'probe_event' && payload.key?('data')
          redacted_payload['data'] = payload['data']
        end
      end

      def preserve_probe_snapshot_values!(payload, redacted_payload)
        original_items = payload.dig('probe_data', 'items')
        redacted_items = redacted_payload.dig('probe_data', 'items')
        return unless original_items.is_a?(Array) && redacted_items.is_a?(Array)

        original_items.zip(redacted_items).each do |original, redacted|
          redacted['data'] = original['data'] if original.is_a?(Hash) && redacted.is_a?(Hash)
        end
      end

      def service_name = config.service || DEFAULT_SERVICE_NAME

      def environment_name = config.environment || DEFAULT_ENVIRONMENT

      def correlation_payload(context)
        request = object_to_hash(context['request'])
        correlation = object_to_hash(context['correlation'])
        {
          'request_id' => correlation['request_id'] || request['request_id'] || context['request_id'],
          'trace_id' => correlation['trace_id'] || request['trace_id'] || context['trace_id'],
          'session_id' => correlation['session_id'] || context['session_id'],
          'user_id_hash' => correlation['user_id_hash'] || context['user_id_hash']
        }
      end

      def event_context(context)
        object_to_hash(context).except(
          'request',
          'response',
          'correlation',
          'request_id',
          'trace_id',
          'session_id',
          'user_id_hash'
        )
      end

      def object_to_hash(value)
        case value
        when Hash
          stringify_hash(value)
        else
          return stringify_hash(value.to_h) if value.respond_to?(:to_h)
          return stringify_hash(value.to_hash) if value.respond_to?(:to_hash)

          {}
        end
      rescue StandardError
        {}
      end

      def sanitized_headers(headers)
        stringify_hash(headers).each_with_object({}) do |(key, value), result|
          normalized_key = key.to_s.downcase
          next unless DEFAULT_HEADER_ALLOWLIST.include?(normalized_key)

          result[normalized_key] = @redactor.redact_value(value)
        end
      end

      def normalize_level(level)
        candidate = level.to_s.strip.downcase.to_sym
        return candidate if LOG_LEVEL_RANKS.key?(candidate)

        :warning
      end

      def level_enabled?(level)
        threshold = [normalize_level(config.log_level), policy_log_level].max_by do |entry|
          LOG_LEVEL_RANKS.fetch(entry)
        end
        LOG_LEVEL_RANKS.fetch(level) >= LOG_LEVEL_RANKS.fetch(threshold)
      end

      def policy_log_level
        case @capture_policy.capture_logs
        when 'off'
          :fatal
        when 'error'
          :error
        when 'info'
          :info
        else
          :warning
        end
      end
    end

    include EventSupport
  end
end
