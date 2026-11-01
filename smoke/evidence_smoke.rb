# frozen_string_literal: true

require 'securerandom'
require 'tmpdir'

module EvidenceSmoke
  FEATURES = %w[exception_evidence_v1 resource_observations_v1 recovery_v1 evidence_provenance_v1].freeze
  DESCRIPTOR = { 'version' => 1, 'features' => FEATURES }.freeze

  module_function

  def enabled? = Gem::Version.new(ENV.fetch('DEBUGBUNDLE_EXPECTED_VERSION')) >= Gem::Version.new('2.1.0')

  def capture(client)
    result = client.with_operation_context(kind: 'job', name: 'installed.fixture', limit_ms: 5000) do
      failure = SecureRandom.uuid
      attempt = SecureRandom.uuid
      begin
        begin
          raise ArgumentError, 'installed inner'
        rescue ArgumentError
          raise 'installed outer'
        end
      rescue RuntimeError => e
        client.capture_exception(e, context: { failure_ref: failure })
      end
      %w[attempt_started attempt_completed recovery_observed].each do |state|
        client.capture_recovery(failure_ref: failure, attempt_id: attempt, state: state)
      end
      10.times do |index|
        client.capture_log("installed byte-bound #{index}", level: :error,
                                                            context: 20.times.to_h do |key|
                                                              ["detail_#{key}", 'x' * 2000]
                                                            end)
      end
      42
    end
    assert!(result == 42, 'installed_operation_return_changed')
  end

  def relay_events
    corpus = JSON.parse(File.read(ENV.fetch('DEBUGBUNDLE_WIRE_CORPUS')))
    error = corpus.fetch('events').find { |fixture| fixture['id'] == 'native_graph' }.fetch('event')
    observation = corpus.fetch('events').find { |fixture| fixture['id'] == 'operation_recovery' }.fetch('event')
    reference = { 'version' => 1, 'failure_ref' => SecureRandom.uuid,
                  'scope' => { 'kind' => 'page', 'page_id' => SecureRandom.uuid } }
    [error, observation].each do |event|
      event['event_id'] = SecureRandom.uuid
      event['occurred_at'] = Time.now.utc.iso8601
      event['correlation']['session_id'] = '0'
    end
    error['context'] = { 'evidence_reference' => reference }
    observation['payload'].merge!(reference)
    observation['payload']['attempt_id'] = SecureRandom.uuid
    [error, observation]
  end

  def verify(events)
    events.each { |event| assert!(DebugBundle::BeforeSend.valid?(event), "installed_noncanonical_#{event['event_type']}") }
    error = events.find do |event|
      event['event_type'] == 'backend_exception' && event.dig('payload', 'message') == 'installed outer'
    end
    assert!(error&.dig('payload', 'exception_evidence', 'nodes')&.length.to_i >= 2, 'installed_native_cause_missing')
    assert!(error.dig('payload', 'execution', 'kind') == 'job', 'installed_operation_metadata_missing')
    reference = error.dig('context', 'evidence_reference')
    observations = events.select do |event|
      event['event_type'] == 'diagnostic_context' && event.dig('payload', 'failure_ref') == reference['failure_ref']
    end
    states = observations.map { |event| event.dig('payload', 'state') }
    assert!(states == %w[attempt_started attempt_completed recovery_observed],
            "installed_recovery_missing_or_reordered:#{states.inspect}")
    assert!(observations.all? do |event|
      event.dig('payload', 'scope') == reference['scope']
    end, 'installed_scope_mismatch')
    logs = events.select { |event| event.dig('payload', 'message')&.start_with?('installed byte-bound ') }
    assert!(logs.length == 10, 'installed_byte_chunk_primary_missing')
  end

  def fatal(endpoint)
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      calls = 0
      at_exit do
        writer.write(calls.to_s)
        writer.close
      end
      # The application explicitly owns its bounded shutdown flush. Automatic
      # process-exit delivery alone remains best-effort.
      at_exit { DebugBundle.flush }
      DebugBundle.init(project_token: PROJECT_TOKEN, service: 'fatal-fixture', environment: 'production',
                       endpoint: endpoint, evidence_capabilities: DESCRIPTOR,
                       before_send: lambda { |_event|
                         calls += 1
                         nil
                       })
      raise 'installed native fatal'
    end
    writer.close
    status = nil
    Timeout.timeout(8) { _, status = Process.wait2(pid) }
    pid = nil
    assert!(!status.success?, 'installed_native_fatal_was_swallowed')
    assert!(reader.read == '0', 'installed_native_fatal_invoked_hook')
  ensure
    Process.kill('KILL', pid) if pid
    reader&.close
    writer&.close
  end

  def verify_local
    Dir.mktmpdir('installed-evidence-') do |directory|
      client = DebugBundle::Client.new(project_mode: :local_only, project_token: 'synthetic',
                                       local_events_dir: directory, flush_interval: 3600, batch_size: 1000,
                                       evidence_capabilities: DESCRIPTOR, capture_recovery_observations: true)
      capture(client)
      client.flush
      Timeout.timeout(5) { sleep(0.01) until client.buffered_event_count.zero? }
      files = Dir.glob(File.join(directory, '*.events.json'))
      assert!(!files.empty?, 'installed_local_batch_missing')
      verify(files.flat_map { |path| JSON.parse(File.read(path)) }.sort_by { |event| event['occurred_at'] })
    ensure
      client&.close
    end
  end
end
