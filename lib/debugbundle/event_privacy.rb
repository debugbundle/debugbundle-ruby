# frozen_string_literal: true

require 'json'
require 'debugbundle/browser_event_privacy'
require 'debugbundle/evidence_graph'
require 'debugbundle/evidence_resources'
require 'debugbundle/evidence_value'
require 'debugbundle/evidence_wire'
require 'debugbundle/telemetry_privacy'

module DebugBundle
  # Schema-aware event boundary preserving validated closed SDK protocol structures
  # while scrubbing all application data and nested free-text/URL fields.
  module EventPrivacy
    ALLOWED_EVIDENCE_LIMIT_OPTIONAL = %w[exception_evidence execution resource_observations].freeze
    ALLOWED_EVIDENCE_LIMIT_REASONS = %w[budget_exceeded unsafe unsupported unknown].freeze
    HASH_EACH_PAIR = Hash.instance_method(:each_pair)
    HASH_FETCH = Hash.instance_method(:fetch)
    HASH_KEY = Hash.instance_method(:key?)

    module_function

    def protect(event, additional_fields: TelemetryPrivacy::EMPTY_ARRAY, exact_fields: TelemetryPrivacy::EMPTY_ARRAY)
      return nil unless EvidenceValue.type?(event, Hash)

      opts = { additional_fields: additional_fields, exact_fields: exact_fields }
      return nil unless TelemetryPrivacy.safe_event_identity?(event, **opts)

      raw_service = HASH_FETCH.bind_call(event, 'service', nil)
      raw_payload = shallow_copy_hash(HASH_FETCH.bind_call(event, 'payload', nil))
      return nil unless EvidenceValue.type?(raw_service, Hash) && raw_payload

      has_context = HASH_KEY.bind_call(event, 'context')
      raw_context = has_context ? shallow_copy_hash(HASH_FETCH.bind_call(event, 'context', nil)) : {}
      return nil if has_context && raw_context.nil?

      event_type = HASH_FETCH.bind_call(event, 'event_type', nil)
      if event_type == 'analytics_event'
        return protect_plain_event(event, raw_service, raw_payload, has_context, raw_context, opts)
      end

      diagnostic_payload, preserved_payload = extract_protocol_payload(event_type, raw_payload, opts)
      return nil if diagnostic_payload == :invalid || preserved_payload == :invalid

      preserved_context = has_context ? extract_protocol_context(raw_context) : {}
      assemble_protected(event, raw_service, raw_payload, diagnostic_payload, preserved_payload,
                         has_context, raw_context, preserved_context, opts)
    rescue StandardError
      nil
    end

    def protect_plain_event(event, raw_service, raw_payload, has_context, raw_context, opts)
      fields = TelemetryPrivacy.protect(
        { 'service' => raw_service, 'payload' => raw_payload, 'context' => raw_context }, **opts
      )
      return nil unless valid_protected_envelope?(fields, has_context)

      event.merge('service' => fields['service'], 'payload' => fields['payload']).tap do |protected|
        protected['context'] = fields['context'] if has_context
      end
    end

    def assemble_protected(event, raw_service, raw_payload, diagnostic_payload, preserved_payload,
                           has_context, raw_context, preserved_context, opts)
      fields = TelemetryPrivacy.protect(
        { 'service' => raw_service, 'payload' => diagnostic_payload.nil? ? raw_payload : {}, 'context' => raw_context },
        **opts
      )
      return nil unless valid_protected_envelope?(fields, has_context)

      protected_payload = diagnostic_payload || fields['payload'].merge(preserved_payload)
      protected_context = fields['context'].merge(preserved_context) if has_context
      assembled = { 'service' => fields['service'], 'payload' => protected_payload }
      assembled['context'] = protected_context if has_context
      return nil if JSON.generate(assembled).bytesize > TelemetryPrivacy::MAX_BYTES

      event.merge('service' => fields['service'], 'payload' => protected_payload).tap do |protected|
        protected['context'] = protected_context if has_context
      end
    end

    def valid_protected_envelope?(fields, has_context)
      fields.is_a?(Hash) &&
        fields['service'].is_a?(Hash) && fields['payload'].is_a?(Hash) &&
        fields['service']['name'].is_a?(String) && fields['service']['environment'].is_a?(String) &&
        (!has_context || fields['context'].is_a?(Hash))
    end

    def extract_protocol_payload(event_type, raw_payload, opts)
      if event_type == 'diagnostic_context'
        sanitized = sanitize_diagnostic_context(raw_payload, opts)
        return [sanitized || :invalid, {}]
      end

      preserved = {}
      return %i[invalid invalid] unless extract_frontend_blocks(event_type, raw_payload, preserved, opts)
      return %i[invalid invalid] unless extract_exception_blocks(event_type, raw_payload, preserved, opts)

      if event_type == 'error_suppressed' && raw_payload['reason'] == 'queue_pressure'
        preserved['reason'] = 'queue_pressure'
        raw_payload.delete('reason')
      end
      [nil, preserved]
    end

    def extract_frontend_blocks(event_type, raw_payload, preserved, opts)
      return true unless event_type == 'frontend_exception'

      extract_field(raw_payload, preserved, 'browser_event') do |value|
        BrowserEventPrivacy.sanitize_browser_event(value, opts)
      end && extract_field(raw_payload, preserved, 'rejection_reason') do |value|
        BrowserEventPrivacy.sanitize_rejection_reason(value, opts)
      end && extract_field(raw_payload, preserved, 'resource_observations') do |value|
        sanitize_resource_observations(value, opts)
      end
    end

    def extract_exception_blocks(event_type, raw_payload, preserved, opts)
      if %w[backend_exception frontend_exception].include?(event_type)
        ok = extract_field(raw_payload, preserved, 'exception_evidence') do |value|
          sanitize_exception_evidence(value, opts)
        end
        return false unless ok
      end
      return true unless event_type == 'backend_exception'

      extract_field(raw_payload, preserved, 'execution') { |value| sanitize_execution(value, opts) }
    end

    def extract_field(raw_payload, preserved, key)
      return true unless raw_payload.key?(key) && !raw_payload[key].nil?

      sanitized = yield(raw_payload[key])
      return false if sanitized == :invalid

      if sanitized
        preserved[key] = sanitized
        raw_payload.delete(key)
      end
      true
    end

    def extract_protocol_context(raw_context)
      preserved = {}
      if raw_context.key?('evidence_reference')
        valid_ref = EvidenceWire.reference(raw_context['evidence_reference'])
        if valid_ref
          preserved['evidence_reference'] = valid_ref
          raw_context.delete('evidence_reference')
        end
      end
      if raw_context.key?('evidence_limits')
        valid_limits = valid_evidence_limits(raw_context['evidence_limits'])
        if valid_limits
          preserved['evidence_limits'] = valid_limits
          raw_context.delete('evidence_limits')
        end
      end
      preserved
    end

    def sanitize_diagnostic_context(raw, opts)
      owned = EvidenceValue.copy(raw)
      return nil unless EvidenceWire.diagnostic(owned)

      if owned['kind'] == 'recovery'
        if owned.key?('operation')
          scrubbed = BrowserEventPrivacy.scrub_string(owned['operation'], opts)
          return nil unless scrubbed && scrubbed.bytesize <= 64

          owned['operation'] = scrubbed
        end
        return owned
      end
      observations = sanitize_resource_observations(owned['observations'], opts)
      return nil unless observations.is_a?(Hash)

      owned['observations'] = observations
      owned
    end

    def sanitize_exception_evidence(raw, opts)
      owned = EvidenceValue.copy(raw)
      return :invalid if owned.equal?(EvidenceValue::INVALID)
      return nil unless EvidenceGraph.valid?(owned, check_byte_budget: false)

      nodes = owned['nodes'].map { |node| sanitize_evidence_node(node, opts) }
      return nil if nodes.any?(&:nil?)

      {
        'version' => owned['version'], 'runtime' => owned['runtime'], 'root_id' => owned['root_id'],
        'nodes' => nodes, 'truncated' => owned['truncated'], 'unavailable_reason' => owned['unavailable_reason']
      }
    end

    def sanitize_evidence_node(node, opts)
      name = BrowserEventPrivacy.scrub_string(node['name'], opts)
      message = BrowserEventPrivacy.scrub_string(node['message'], opts)
      stack = if node['stack'].nil?
                nil
              else
                BrowserEventPrivacy.scrub_string(BrowserEventPrivacy.sanitize_browser_stack_urls(node['stack']), opts)
              end
      return nil if name.nil? || message.nil? || (!node['stack'].nil? && stack.nil?)

      frames = node['frames'].map { |frame| sanitize_evidence_frame(frame, opts) }
      return nil if frames.any?(&:nil?)

      {
        'id' => node['id'], 'name' => name, 'message' => message, 'stack' => stack,
        'trace_origin' => node['trace_origin'], 'parsing_status' => node['parsing_status'],
        'frames' => frames, 'relationships' => node['relationships']
      }
    end

    def sanitize_evidence_frame(frame, opts)
      fn = frame['function'].nil? ? nil : BrowserEventPrivacy.scrub_string(frame['function'], opts)
      file = if frame['file'].nil?
               nil
             else
               BrowserEventPrivacy.scrub_string(BrowserEventPrivacy.sanitize_browser_stack_urls(frame['file']), opts)
             end
      return nil if (!frame['function'].nil? && fn.nil?) || (!frame['file'].nil? && file.nil?)

      { 'function' => fn, 'file' => file, 'line' => frame['line'],
        'column' => frame['column'], 'classification' => frame['classification'] }
    end

    def sanitize_execution(raw, opts)
      owned = EvidenceValue.copy(raw)
      return :invalid if owned.equal?(EvidenceValue::INVALID)
      return nil unless EvidenceWire.execution(owned)

      name = owned['name'].nil? ? nil : BrowserEventPrivacy.scrub_string(owned['name'], opts)
      return nil if !owned['name'].nil? && name.nil?

      { 'version' => owned['version'], 'kind' => owned['kind'], 'name' => name,
        'elapsed_ms' => owned['elapsed_ms'], 'limit_ms' => owned['limit_ms'] }
    end

    def sanitize_resource_observations(raw, opts)
      owned = EvidenceValue.copy(raw)
      return :invalid if owned.equal?(EvidenceValue::INVALID)
      return nil unless EvidenceResources.valid?(owned)

      items = owned['items'].map do |item|
        source_url = item['source_url'].nil? ? nil : BrowserEventPrivacy.scrub_string(item['source_url'], opts)
        return nil if !item['source_url'].nil? && source_url.nil?

        item.merge('source_url' => source_url)
      end
      { 'version' => owned['version'], 'items' => items }
    end

    def valid_evidence_limits(raw)
      owned = EvidenceValue.copy(raw)
      return nil unless EvidenceWire.closed(owned, ['version'], ALLOWED_EVIDENCE_LIMIT_OPTIONAL)
      return nil unless EvidenceWire.integer(owned['version'], 1, 1)
      return nil unless owned.all? { |key, value| key == 'version' || ALLOWED_EVIDENCE_LIMIT_REASONS.include?(value) }

      owned
    end

    def shallow_copy_hash(value)
      return nil unless EvidenceValue.type?(value, Hash)

      clone = {}
      HASH_EACH_PAIR.bind_call(value) { |key, item| clone[key] = item }
      clone
    end
  end
end
