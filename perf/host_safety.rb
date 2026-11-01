# frozen_string_literal: true

require 'json'
require 'timeout'
require 'debugbundle'

def elapsed_seconds
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

def check(condition, message)
  raise message unless condition
end

filtered_client = DebugBundle::Client.new(
  project_token: 'dbundle_proj_synthetic', log_level: :warning,
  transport: ->(_request) { raise 'filtered logs must not send' }
)
filtered_seconds = Timeout.timeout(10) do
  elapsed_seconds do
    10_000.times { filtered_client.capture_log('filtered info', level: :info, context: { index: 1 }) }
  end
end
check(filtered_seconds < 2.0, "filtered_10k_budget_exceeded:#{filtered_seconds}")
check(filtered_client.buffered_event_count.zero?, 'filtered_logs_retained')
filtered_client.close

configured_client = DebugBundle::Client.new(
  project_token: 'dbundle_proj_synthetic', batch_size: 1_001, flush_interval: 60,
  redact_fields: Array.new(8) { |index| "private_field_#{index}" },
  transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) }
)
configured_seconds = Timeout.timeout(10) do
  elapsed_seconds do
    1_000.times { configured_client.capture_log('accepted error', level: :error) }
  end
end
check(configured_seconds < 1.5, "configured_privacy_1k_budget_exceeded:#{configured_seconds}")
check(configured_client.buffered_event_count == 1_000, 'configured_privacy_events_missing')
configured_client.close

entered = Queue.new
release = Queue.new
slow_transport = lambda do |_request|
  entered << true
  release.pop
  DebugBundle::Transport::Result.new(status_code: 202)
end
client = DebugBundle::Client.new(
  project_token: 'dbundle_proj_synthetic', batch_size: 1,
  flush_interval: 60, transport: slow_transport
)
at_exit do
  release << true
  client.close
  filtered_client.close
end
client.capture_log('first error', level: :error)
Timeout.timeout(3) { entered.pop }
accepted_seconds = Timeout.timeout(10) do
  elapsed_seconds do
    999.times { client.capture_log('accepted error', level: :error) }
  end
end
check(client.buffered_event_count == 1_000, 'queue_not_filled')
check(accepted_seconds < 1.5, "accepted_1k_budget_exceeded:#{accepted_seconds}")

concurrent_seconds = Timeout.timeout(10) do
  elapsed_seconds do
    callers = Array.new(8) do
      Thread.new { 1_250.times { client.capture_log('burst error', level: :error) } }
    end
    callers.each(&:join)
  end
end
check(concurrent_seconds < 5.0, "held_transport_10k_budget_exceeded:#{concurrent_seconds}")
check(client.buffered_event_count <= 1_000, 'queue_count_budget_exceeded')
check(client.instance_variable_get(:@buffer_bytes) <= 8 * 1_024 * 1_024, 'queue_byte_budget_exceeded')
check(client.instance_variable_get(:@pressure_drops).fetch('error').fetch(:count).positive?, 'full_queue_not_exercised')

def evidence_error(index)
  inner = ArgumentError.new("inner #{index}")
  inner.set_backtrace(Array.new(24) { |line| "app/jobs/inner.rb:#{line + 1}:in `process'" })
  raise RuntimeError.new("outer #{index}"), cause: inner
rescue RuntimeError => e
  e.set_backtrace(Array.new(24) { |line| "app/jobs/outer.rb:#{line + 1}:in `perform'" })
  e
end

evidence_entered = Queue.new
evidence_release = Queue.new
evidence_client = DebugBundle::Client.new(
  project_token: 'synthetic', batch_size: 1, flush_interval: 60,
  evidence_capabilities: { version: 1, features: DebugBundle::EvidenceWire::FEATURES },
  capture_recovery_observations: true,
  transport: lambda { |_request|
    evidence_entered << true
    evidence_release.pop
    DebugBundle::Transport::Result.new(status_code: 202)
  }
)
at_exit do
  evidence_release << true
  evidence_client.close
end
evidence_client.capture_exception(evidence_error(-1))
Timeout.timeout(3) { evidence_entered.pop }
evidence_seconds = Timeout.timeout(10) do
  elapsed_seconds do
    evidence_client.with_operation_context(kind: :job, name: 'performance.fixture') do
      200.times { |index| evidence_client.capture_exception(evidence_error(index)) }
    end
  end
end
check(evidence_seconds < 1.5, "enriched_200_budget_exceeded:#{evidence_seconds}")
check(evidence_client.buffered_event_count == 201, 'enriched_primary_events_missing')
check(evidence_client.instance_variable_get(:@buffer_bytes) <= 8 * 1_024 * 1_024, 'enriched_bytes_unbounded')
recovery_seconds = Timeout.timeout(10) do
  elapsed_seconds do
    50.times do
      fields = { failure_ref: SecureRandom.uuid, attempt_id: SecureRandom.uuid, state: 'attempt_completed',
                 evidence_scope: { kind: :operation, operation_id: SecureRandom.uuid } }
      20.times { evidence_client.capture_recovery(fields) }
    end
  end
end
check(recovery_seconds < 1.5, "recovery_1k_budget_exceeded:#{recovery_seconds}")
check(evidence_client.instance_variable_get(:@diagnostics).accounted_bytes <= 65_536, 'recovery_bytes_unbounded')

puts JSON.generate(
  ruby_version: RUBY_VERSION,
  filtered_10k_seconds: filtered_seconds.round(4),
  configured_privacy_1k_seconds: configured_seconds.round(4),
  accepted_1k_seconds: accepted_seconds.round(4),
  held_transport_concurrent_10k_seconds: concurrent_seconds.round(4),
  enriched_200_seconds: evidence_seconds.round(4),
  recovery_1k_seconds: recovery_seconds.round(4),
  retained_count: client.buffered_event_count,
  retained_bytes: client.instance_variable_get(:@buffer_bytes)
)
