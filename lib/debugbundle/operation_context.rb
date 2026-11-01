# frozen_string_literal: true

require 'securerandom'
require 'debugbundle/evidence_wire'
require 'debugbundle/telemetry_privacy'

module DebugBundle
  # Thread#[] is Fiber-local on the supported Ruby floor. New Fibers and threads
  # do not inherit request ownership; completed/closed generations are revoked.
  class OperationContext
    def initialize
      @key = :"__debugbundle_operation_#{object_id}"
      @generation = 0
    end

    def current
      lease = Thread.current[@key]
      return nil unless lease && lease[:generation] == @generation && lease[:active]
      return nil unless lease[:parents].all? { |parent| parent[:active] }

      lease
    end

    def begin_scope(kind:, name: nil, limit_ms: nil, correlation: nil)
      previous = current
      parents = previous ? previous[:parents] + [previous] : []
      return nil if parents.length > 15

      owned_kind = EvidenceValue.options(kind)
      owned_name = EvidenceValue.copy(name)
      owned_limit = EvidenceValue.copy(limit_ms)
      owned_kind = 'unknown' unless %w[request command job unknown].include?(owned_kind)
      unless EvidenceWire.text(owned_name,
                               128) && !owned_name.empty? && TelemetryPrivacy.protect(owned_name) == owned_name
        owned_name = nil
      end
      owned_limit = nil unless EvidenceWire.number(owned_limit)
      lease = { generation: @generation, active: true, parents: parents, previous: previous,
                scope: { 'kind' => 'operation', 'operation_id' => SecureRandom.uuid },
                kind: owned_kind, name: owned_name, limit: owned_limit,
                correlation: scoped_correlation(previous, correlation),
                started: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      Thread.current[@key] = lease
      lease
    rescue StandardError
      nil
    end

    def end_scope(lease)
      return unless lease

      lease[:active] = false
      return unless Thread.current[@key].equal?(lease)

      Thread.current[@key] = lease[:generation] == @generation ? lease[:previous] : nil
    rescue StandardError
      nil
    end

    def snapshot
      lease = current
      return nil unless lease

      { 'version' => 1, 'kind' => lease[:kind], 'name' => lease[:name], 'limit_ms' => lease[:limit],
        'elapsed_ms' => [(Process.clock_gettime(Process::CLOCK_MONOTONIC) - lease[:started]) * 1000, 0].max }
    end

    def scope = current&.fetch(:scope)&.dup

    def scoped_correlation(previous, input)
      owned = EvidenceValue.options(input)
      selected = {}
      if owned.is_a?(Hash)
        %w[request_id trace_id session_id user_id_hash].each do |field|
          value = owned[field]
          next unless EvidenceWire.text(value, 256) && !value.strip.empty?
          next unless TelemetryPrivacy.protect(value) == value

          selected[field] = value
        end
      end
      (previous ? previous[:correlation] : {}).merge(selected)
    end

    def clear
      @generation += 1
      Thread.current[@key] = nil
    end
  end
end
