# frozen_string_literal: true

require 'time'
require 'date'
require 'uri'
require 'debugbundle/evidence_value'
require 'debugbundle/evidence_json'
require 'debugbundle/evidence_graph'
require 'debugbundle/evidence_resources'

module DebugBundle
  # Only additive evidence is closed here. Historical arbitrary context remains
  # open, including an application-defined invalid same-named reference field.
  module EvidenceWire
    FEATURES = %w[exception_evidence_v1 resource_observations_v1 recovery_v1 evidence_provenance_v1].freeze
    UUID = /\A[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\z/i
    FRESH_UUID = /\A[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}\z/i
    UTC_TIME = /\A\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d+)?Z\z/

    module_function

    def closed(value, required, optional = [])
      value.is_a?(Hash) && (required - value.keys).empty? && (value.keys - required - optional).empty?
    end

    def number(value)
      (value.is_a?(Integer) || value.is_a?(Float)) && value >= 0 && value.to_f.finite?
    end

    def integer(value, minimum, maximum = nil)
      number(value) && value == value.floor && value >= minimum && (!maximum || value <= maximum)
    end

    def text(value, maximum) = value.is_a?(String) && value.valid_encoding? && value.bytesize <= maximum
    def uuid(value, fresh: false) = text(value, 36) && (fresh ? FRESH_UUID : UUID).match?(value)

    def timestamp(value)
      text(value, 32_768) && UTC_TIME.match?(value) && !!Date.iso8601(value[0, 10])
    rescue ArgumentError
      false
    end

    def descriptor(value)
      owned = EvidenceValue.copy(value)
      empty = { 'version' => 1, 'features' => [] }
      return empty unless closed(owned, %w[version features]) && integer(owned['version'], 1, 1)

      features = owned['features']
      return empty unless features.is_a?(Array) && features.length <= 4 && (features - FEATURES).empty?
      return empty unless features.uniq.length == features.length

      { 'version' => 1, 'features' => FEATURES & features }
    end

    def scope(value)
      return false unless value.is_a?(Hash)

      field = { 'page' => 'page_id', 'operation' => 'operation_id' }[value['kind']]
      field && closed(value, ['kind', field]) && uuid(value[field], fresh: true)
    end

    def reference(value)
      owned = EvidenceValue.copy(value)
      return nil unless closed(owned, %w[version failure_ref scope]) && integer(owned['version'], 1, 1)
      return nil unless uuid(owned['failure_ref'], fresh: true) && scope(owned['scope'])

      owned
    end

    def capture_reference(value, default_scope = nil)
      owned = EvidenceValue.copy(value)
      return nil unless owned.is_a?(Hash)

      reference('version' => 1, 'failure_ref' => owned['failure_ref'],
                'scope' => owned['evidence_scope'] || default_scope)
    end

    def recovery(value, default_scope = nil)
      owned = EvidenceValue.copy(value)
      selected = capture_reference(owned, default_scope)
      return nil unless selected

      payload = selected.merge('kind' => 'recovery', 'attempt_id' => owned['attempt_id'], 'state' => owned['state'])
      %w[operation status_code duration_ms].each { |field| payload[field] = owned[field] if owned.key?(field) }
      diagnostic(payload) ? payload : nil
    end

    def diagnostic(value)
      return false unless value.is_a?(Hash) && reference(value.slice('version', 'failure_ref', 'scope'))

      if value['kind'] == 'recovery'
        closed(value, %w[version kind failure_ref scope attempt_id state], %w[operation status_code duration_ms]) &&
          uuid(value['attempt_id'], fresh: true) &&
          %w[attempt_started attempt_completed attempt_failed recovery_observed
             failure_persisted].include?(value['state']) &&
          (!value.key?('operation') || text(value['operation'], 64)) &&
          (!value.key?('status_code') || integer(value['status_code'], 100, 599)) &&
          (!value.key?('duration_ms') || number(value['duration_ms']))
      else
        value['kind'] == 'resource_observation' &&
          closed(value, %w[version kind failure_ref scope source_event_id observations]) &&
          uuid(value['source_event_id']) && EvidenceResources.valid?(value['observations'])
      end
    end

    def execution(value)
      closed(value, %w[version kind name elapsed_ms limit_ms]) && integer(value['version'], 1, 1) &&
        %w[request command job unknown].include?(value['kind']) &&
        (value['name'].nil? || text(value['name'], 128)) &&
        (value['elapsed_ms'].nil? || number(value['elapsed_ms'])) &&
        (value['limit_ms'].nil? || number(value['limit_ms']))
    end

    def valid_optional?(event)
      return false unless EvidenceValue.type?(event, Hash)

      payload = Hash.instance_method(:fetch).bind_call(event, 'payload', nil)
      return false unless EvidenceValue.type?(payload, Hash)

      type = EvidenceValue.copy(Hash.instance_method(:fetch).bind_call(event, 'event_type', nil))
      return valid_context?(event, EvidenceValue.copy(payload)) if type == 'diagnostic_context'

      additions = {}
      { 'exception_evidence' => EvidenceGraph, 'execution' => self,
        'resource_observations' => EvidenceResources }.each do |field, validator|
        next unless Hash.instance_method(:key?).bind_call(payload, field)
        return false unless allowed_field?(type, field)

        owned = EvidenceValue.copy(Hash.instance_method(:fetch).bind_call(payload, field))
        return false unless field == 'execution' ? execution(owned) : validator.valid?(owned)

        additions[field] = owned
      end
      return true if additions.empty?

      context = Hash.instance_method(:fetch).bind_call(event, 'context', nil)
      if EvidenceValue.type?(
        context, Hash
      )
        selected = reference(Hash.instance_method(:fetch).bind_call(context, 'evidence_reference',
                                                                    nil))
      end
      additions['evidence_reference'] = selected if selected
      EvidenceJson.bytes(additions) <= 32_768
    rescue StandardError
      false
    end

    def allowed_field?(type, field)
      (type == 'backend_exception' && field != 'resource_observations') ||
        (type == 'frontend_exception' && field != 'execution')
    end

    def valid_context?(event, payload)
      return false unless diagnostic(payload)
      return true unless payload['scope']['kind'] == 'page'

      correlation = Hash.instance_method(:fetch).bind_call(event, 'correlation', nil)
      return false unless EvidenceValue.type?(correlation, Hash)

      session = Hash.instance_method(:fetch).bind_call(correlation, 'session_id', nil)
      EvidenceValue.type?(session, String) && !String.new(session).strip.empty?
    end

    def supported(event, features)
      payload = event['payload']
      if event['event_type'] == 'diagnostic_context'
        feature = payload['kind'] == 'recovery' ? 'recovery_v1' : 'resource_observations_v1'
        return features.include?(feature) ? event : nil
      end
      filtered = payload.dup
      filtered = filtered.except('exception_evidence', 'execution') unless features.include?('exception_evidence_v1')
      filtered.delete('resource_observations') unless features.include?('resource_observations_v1')
      result = filtered == payload ? event : event.merge('payload' => filtered)
      context = event['context']
      reference_disabled = !features.intersect?(%w[recovery_v1 resource_observations_v1])
      if reference_disabled && context.is_a?(Hash) && reference(context['evidence_reference'])
        result = result.merge('context' => context.except('evidence_reference'))
      end
      result
    end

    def without_optional(event)
      return nil unless event.is_a?(Hash) && %w[backend_exception frontend_exception].include?(event['event_type'])

      payload = event['payload']
      return nil unless payload.is_a?(Hash)

      stripped = payload.except('exception_evidence', 'execution', 'resource_observations')
      stripped == payload ? nil : event.merge('payload' => stripped)
    end
  end
end
