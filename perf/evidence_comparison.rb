# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'timeout'
require 'debugbundle'

# Compare identical calls without timing setup, queue seeding, error creation or
# cleanup. The sender stays idle until cleanup, so allocation counts describe SDK
# capture on this process rather than application rendering or network activity.
def comparison_error(index)
  inner = ArgumentError.new("inner #{index}")
  inner.set_backtrace(["app/inner.rb:12:in `process'"])
  raise RuntimeError.new("outer #{index}"), cause: inner
rescue RuntimeError => e
  e.set_backtrace(["app/outer.rb:24:in `perform'"])
  e
end

def comparison_calls
  Array.new(20) do |index|
    reference = SecureRandom.uuid
    scope = { kind: :operation, operation_id: SecureRandom.uuid }
    [comparison_error(index), { failure_ref: reference, evidence_scope: scope },
     { failure_ref: reference, evidence_scope: scope, attempt_id: SecureRandom.uuid,
       state: :attempt_completed, status_code: 200 }]
  end
end

def compare_evidence(enabled:, pressure:)
  client = DebugBundle::Client.new(
    project_token: 'synthetic', batch_size: 1001, flush_interval: 3600,
    capture_exception_evidence: enabled, capture_recovery_observations: enabled,
    evidence_capabilities: { version: 1, features: DebugBundle::EvidenceWire::FEATURES },
    transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) }
  )
  if pressure
    1000.times { |index| client.capture_log("warning #{index}", level: :warning) }
    raise 'warning queue was not filled' unless client.buffered_event_count == 1000
  end
  calls = comparison_calls
  GC.start
  allocations = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  calls.each do |error, context, observation|
    client.capture_exception(error, context: context)
    client.capture_recovery(observation)
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  allocations = GC.stat(:total_allocated_objects) - allocations

  retained = client.instance_variable_get(:@buffer)
  failures = retained.select { |event| event['event_type'] == 'backend_exception' }
  raise 'original failures were displaced' unless failures.length == calls.length
  unless failures.all? { |event| event['payload'].key?('exception_evidence') == enabled }
    raise 'evidence comparison did not exercise the requested mode'
  end

  diagnostics = retained.count { |event| event['event_type'] == 'diagnostic_context' }
  # Ruby's existing context tier may replace warnings, but never exceptions.
  expected_diagnostics = enabled ? calls.length : 0
  raise 'independent recovery or its lower priority changed' unless diagnostics == expected_diagnostics

  bytes = client.instance_variable_get(:@buffer_bytes)
  diagnostic_bytes = client.instance_variable_get(:@diagnostics).accounted_bytes
  raise 'queue count ceiling exceeded' if retained.length > 1000
  raise 'queue byte ceiling exceeded' if bytes > 8 * 1024 * 1024
  raise 'diagnostic ceiling exceeded' if diagnostic_bytes > 65_536

  { evidence: enabled, pressure: pressure, pairs: calls.length,
    seconds_per_pair: elapsed / calls.length, allocated_objects_per_pair: allocations.fdiv(calls.length),
    retained_count: retained.length, retained_bytes: bytes, diagnostic_bytes: diagnostic_bytes }
ensure
  client&.close
end

# Warm shared schema/runtime paths equally before collecting either mode.
compare_evidence(enabled: true, pressure: false)
3.times do |repeat|
  [false, true].each do |pressure|
    [false, true].each do |enabled|
      result = Timeout.timeout(15) { compare_evidence(enabled: enabled, pressure: pressure) }
      puts JSON.generate(result.merge(ruby_version: RUBY_VERSION, repeat: repeat + 1))
    end
  end
end
