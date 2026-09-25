# frozen_string_literal: true

require 'debugbundle/safe_input'

module DebugBundle
  class Client
    module EventSupport
      private

      def capture_enabled?
        ensure_current_process!
        config.enabled? && config.configured?
      end

      def merge_context(context)
        merged = @context.merge(stringify_hash(context || {}))
        @redactor.redact_value(merged)
      end

      def stringify_hash(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, nested_value), result|
          safe_key = SafeInput.key(key)
          result[safe_key] = nested_value if safe_key
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
        current = safe_exception_cause(error)
        seen = {}.compare_by_identity
        seen[error] = true

        while current && causes.length < 8 && !seen[current]
          seen[current] = true
          causes << {
            'name' => safe_exception_name(current),
            'message' => safe_exception_message(current),
            'stack' => safe_exception_stack(current)
          }
          current = safe_exception_cause(current)
        end

        causes
      end

      def safe_exception_message(error)
        value = Exception.instance_method(:to_s).bind_call(error)
        value.is_a?(String) ? value[0, 4096] : '[exception message unavailable]'
      rescue StandardError
        '[exception message unavailable]'
      end

      def safe_exception_name(error)
        type = Object.instance_method(:class).bind_call(error)
        value = Module.instance_method(:name).bind_call(type)
        value.is_a?(String) && !value.empty? ? value[0, 256] : 'Exception'
      rescue StandardError
        'Exception'
      end

      def safe_exception_stack(error)
        frames = Exception.instance_method(:backtrace).bind_call(error)
        return '' unless frames.is_a?(Array)

        frames.first(64).filter_map { |frame| frame[0, 512] if frame.is_a?(String) }.join("\n")[0, 16_384]
      rescue StandardError
        ''
      end

      def safe_exception_cause(error)
        Exception.instance_method(:cause).bind_call(error)
      rescue StandardError
        nil
      end

      def safe_log_message(value)
        is_a = Object.instance_method(:is_a?)
        return String.instance_method(:[]).bind_call(value, 0, 16_384) if is_a.bind_call(value, String)

        if is_a.bind_call(value, Integer)
          return '[unsupported log message]' if Integer.instance_method(:bit_length).bind_call(value) > 4096

          return Integer.instance_method(:to_s).bind_call(value)
        end
        return Float.instance_method(:to_s).bind_call(value) if is_a.bind_call(value, Float)

        if is_a.bind_call(value, Symbol)
          return '[unsupported log message]' if Symbol.instance_method(:length).bind_call(value) > 16_384

          return Symbol.instance_method(:to_s).bind_call(value)
        end
        return TrueClass.instance_method(:to_s).bind_call(value) if is_a.bind_call(value, TrueClass)
        return FalseClass.instance_method(:to_s).bind_call(value) if is_a.bind_call(value, FalseClass)
        return '' if is_a.bind_call(value, NilClass)

        '[unsupported log message]'
      rescue StandardError
        '[unsupported log message]'
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
        redacted = TelemetryPrivacy.protect(@redactor.redact_value(value), additional_fields: config.redact_fields)
        redacted.is_a?(Hash) ? redacted : { 'value' => redacted }
      rescue StandardError
        { 'value' => '[REDACTED]' }
      end

      def apply_before_send(event)
        protected = protect_event(event)
        return nil unless protected

        prepared = BeforeSend.apply(protected, config.before_send)
        prepared && protect_event(prepared)
      end

      def protect_event(event)
        return nil unless TelemetryPrivacy.safe_event_identity?(event, additional_fields: config.redact_fields)

        fields = TelemetryPrivacy.protect(
          { 'service' => event['service'], 'payload' => event['payload'], 'context' => event['context'] },
          additional_fields: config.redact_fields
        )
        return nil unless fields['service'].is_a?(Hash) && fields['payload'].is_a?(Hash)
        return nil unless fields['service']['name'].is_a?(String) && fields['service']['environment'].is_a?(String)

        event.merge('service' => fields['service'], 'payload' => fields['payload']).tap do |protected|
          protected['context'] = fields['context'] if event.key?('context')
        end
      rescue StandardError
        nil
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
          enqueue_event(base_event('error_suppressed', aggregate, {}))
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
        value.is_a?(Hash) ? stringify_hash(value) : {}
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
        return false if @capture_policy.capture_logs == 'off'

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
