# frozen_string_literal: true

require 'time'
require 'debugbundle/evidence_wire'
require 'debugbundle/canonical_event_schema'

module DebugBundle
  module BeforeSend
    REQUIRED_PAYLOAD_FIELDS = {
      'backend_exception' => %w[name message stack handled request response runtime],
      'request_event' => %w[method path query headers response_status duration_ms],
      'log_event' => %w[level message attributes],
      'frontend_breadcrumb' => %w[breadcrumb_type data],
      'frontend_exception' => %w[name message stack],
      'deploy_metadata' => %w[commit_sha version branch environment deployed_at],
      'error_suppressed' => %w[fingerprint suppressed_count window_seconds first_seen last_seen],
      'probe_event' => %w[label data activation_id probe_label_pattern],
      'diagnostic_context' => %w[version kind failure_ref scope]
    }.freeze
    ALLOWED_PAYLOAD_FIELDS = {
      'backend_exception' => %w[name message stack handled request response runtime probe_data exception_evidence
                                execution],
      'request_event' => %w[
        method path query headers body response_status duration_ms route_template
        response_headers response_body device
      ],
      'log_event' => %w[level message attributes device],
      'frontend_breadcrumb' => %w[breadcrumb_type route data device],
      'frontend_exception' => %w[
        name message stack route browser breadcrumbs device browser_event
        rejection_reason dom_context probe_data exception_evidence resource_observations
      ],
      'deploy_metadata' => %w[commit_sha version branch environment deployed_at],
      'error_suppressed' => %w[fingerprint suppressed_count window_seconds first_seen last_seen reason level device],
      'probe_event' => %w[label data activation_id probe_label_pattern device],
      'diagnostic_context' => %w[version kind failure_ref scope attempt_id state operation status_code duration_ms
                                 source_event_id observations]
    }.freeze
    ROOT_FIELDS = %w[
      schema_version event_id event_type project_token project_id sdk_name sdk_version
      service occurred_at correlation context payload
    ].freeze
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    MOBILE_SDK_NAMES = %w[@debugbundle/sdk-android @debugbundle/sdk-swift @debugbundle/sdk-react-native].freeze

    module_function

    def apply(event, hook)
      return event unless hook

      result = hook.call(Marshal.load(Marshal.dump(event)))
      return nil if result.nil?

      checked = normalization_result(result)
      return nil if checked.equal?(EvidenceValue::EXHAUSTED)

      checked || event
    rescue StandardError
      event
    end

    def valid?(event)
      !normalized(event).nil?
    end

    def normalized(event)
      result = normalization_result(event)
      EvidenceValue.type?(result, Hash) ? result : nil
    end

    def normalization_result(event)
      return nil unless EvidenceValue.type?(event, Hash)
      return nil if Hash.instance_method(:size).bind_call(event) > ROOT_FIELDS.length

      # Local/queued events keep their established ceiling independently of
      # the smaller evidence DTO and HTTP budgets enforced at those boundaries.
      owned = EvidenceValue.copy_with_budget(event, symbol_keys: true, max_bytes: 8 * 1024 * 1024,
                                                    max_string_bytes: 8 * 1024 * 1024)
      return owned if owned.equal?(EvidenceValue::EXHAUSTED)
      return nil unless EvidenceValue.type?(owned, Hash)
      return nil unless CanonicalEventSchema.valid?(owned) && EvidenceWire.valid_optional?(owned)
      return nil unless required_frontend_context?(owned)

      owned
    rescue StandardError
      nil
    end

    # The canonical Zod contract refines this conditional outside its shape;
    # the generated JSON Schema alone cannot establish frontend identity.
    def required_frontend_context?(event)
      return true unless event['event_type'] == 'frontend_exception'

      payload = event['payload']
      MOBILE_SDK_NAMES.include?(event['sdk_name']) ? payload['device'].is_a?(Hash) : payload.key?('browser')
    end

    # Existing shape helpers stay available to integrations. Full acceptance
    # above uses the vendored canonical contract, including nested fields.
    def valid_identity?(event)
      %w[schema_version event_id event_type occurred_at sdk_name sdk_version].all? do |field|
        event[field].is_a?(String) && !event[field].empty?
      end && UUID_PATTERN.match?(event['event_id']) && EvidenceWire.timestamp(event['occurred_at'])
    end

    def valid_payload_shape?(event_type, payload)
      case event_type
      when 'backend_exception'
        valid_backend_exception?(payload)
      when 'request_event'
        valid_request_event?(payload)
      when 'log_event'
        non_empty_strings?(payload, 'level', 'message') && payload['attributes'].is_a?(Hash)
      when 'frontend_breadcrumb'
        non_empty_strings?(payload, 'breadcrumb_type') && payload['data'].is_a?(Hash)
      when 'frontend_exception'
        valid_frontend_exception?(payload)
      when 'deploy_metadata'
        valid_deploy_metadata?(payload)
      when 'error_suppressed'
        valid_error_suppressed?(payload)
      when 'probe_event'
        valid_probe_event?(payload)
      when 'diagnostic_context'
        EvidenceWire.diagnostic(payload)
      else
        false
      end
    end

    def valid_backend_exception?(payload)
      non_empty_strings?(payload, 'name', 'message', 'stack') &&
        [true, false].include?(payload['handled']) &&
        %w[request response runtime].all? { |field| payload[field].is_a?(Hash) } &&
        optional_hash?(payload, 'probe_data')
    end

    def valid_request_event?(payload)
      non_empty_strings?(payload, 'method', 'path') &&
        payload['query'].is_a?(Hash) &&
        payload['headers'].is_a?(Hash) &&
        non_negative_number?(payload['response_status']) &&
        non_negative_number?(payload['duration_ms']) &&
        optional_hash?(payload, 'response_headers')
    end

    def valid_frontend_exception?(payload)
      non_empty_strings?(payload, 'name', 'message', 'stack') &&
        (!payload.key?('breadcrumbs') || payload['breadcrumbs'].is_a?(Array)) &&
        optional_hash?(payload, 'probe_data')
    end

    def valid_deploy_metadata?(payload)
      non_empty_strings?(payload, 'commit_sha', 'version', 'branch', 'environment') &&
        timestamp?(payload['deployed_at'])
    end

    def valid_error_suppressed?(payload)
      non_empty_strings?(payload, 'fingerprint') &&
        non_negative_integer?(payload['suppressed_count']) &&
        positive_integer?(payload['window_seconds']) &&
        timestamp?(payload['first_seen']) &&
        timestamp?(payload['last_seen'])
    end

    def valid_probe_event?(payload)
      non_empty_strings?(payload, 'label', 'probe_label_pattern') &&
        payload['data'].is_a?(Hash) &&
        nullable_uuid?(payload['activation_id'])
    end

    def non_empty_strings?(payload, *fields)
      fields.all? { |field| payload[field].is_a?(String) && !payload[field].strip.empty? }
    end

    def optional_hash?(payload, field)
      !payload.key?(field) || payload[field].is_a?(Hash)
    end

    def non_negative_number?(value)
      value.is_a?(Numeric) && value.finite? && value >= 0
    end

    def non_negative_integer?(value)
      value.is_a?(Integer) && value >= 0
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def timestamp?(value)
      EvidenceWire.timestamp(value)
    end

    def nullable_uuid?(value)
      value.nil? || (value.is_a?(String) && UUID_PATTERN.match?(value))
    end
  end
end
