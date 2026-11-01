# frozen_string_literal: true

require 'debugbundle/evidence_wire'

module DebugBundle
  class EvidenceDelivery
    attr_reader :features

    def initialize(pin = nil)
      @features = EvidenceWire.descriptor(EvidenceValue.options(pin))['features']
    end

    def supports?(feature) = @features.include?(feature)
    def descriptor = { 'version' => 1, 'features' => @features.dup }
    def restrict(features) = @features &= features

    def observe(body, required: false, valid: true)
      owned = EvidenceValue.copy(body)
      supplied = owned.is_a?(Hash) && owned.key?('evidence_capabilities')
      return false unless required || supplied

      previous = @features
      @features = EvidenceWire.descriptor(valid && supplied ? owned['evidence_capabilities'] : nil)['features']
      (previous - @features).any?
    end

    def valid_config?(body)
      owned = EvidenceValue.copy(body)
      return false unless owned.is_a?(Hash)
      return false unless %w[probes_enabled remote_probes_enabled].all? do |field|
        !owned.key?(field) || [true, false].include?(owned[field])
      end
      return false if owned.key?('active_probes') && !owned['active_probes'].is_a?(Array)

      policy = owned['capture_policy']
      return true if policy.nil?
      return false unless policy.is_a?(Hash)

      diagnostic = policy['capture_diagnostic_context']
      return false if policy.key?('capture_diagnostic_context') && ![true, false].include?(diagnostic)

      { 'preset' => %w[minimal balanced investigative], 'capture_logs' => %w[off error warning info],
        'capture_request_events' => %w[off failures_only filtered all],
        'capture_breadcrumbs' => %w[local_only exception_only standalone],
        'capture_probe_events' => %w[buffer_only standalone_when_activated] }.all? do |field, values|
        !policy.key?(field) || values.include?(policy[field])
      end
    end
  end
end
