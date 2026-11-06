# frozen_string_literal: true

require 'spec_helper'
require 'json_schemer'
require 'securerandom'
require 'timeout'
require 'debugbundle/evidence_wire'

RSpec.describe DebugBundle::Client do
  let(:calls) { [] }
  let(:clients) { [] }
  let(:pin) { { 'version' => 1, 'features' => DebugBundle::EvidenceWire::FEATURES } }
  let(:schema) do
    JSONSchemer.schema(JSON.parse(File.read(File.join(__dir__, 'fixtures/event-envelope.schema.json'))))
  end

  def sdk(**options)
    delivered = calls
    transport = lambda do |request|
      delivered.concat(request.fetch(:events))
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                        batch_size: 1000, flush_interval: 3600, **options).tap { |client| clients << client }
  end

  def raised_error
    begin
      raise ArgumentError, 'inner'
    rescue ArgumentError
      raise 'outer'
    end
  rescue RuntimeError => e
    e
  end

  def schema_errors(event)
    schema.validate(event).select { |error| error['schema_pointer'].start_with?('/anyOf/1/') }
                          .map do |error|
      error.slice('data_pointer', 'schema_pointer',
                  'type', 'error')
    end.inspect
  end

  def observation(scope: { 'kind' => 'operation', 'operation_id' => SecureRandom.uuid })
    { 'failure_ref' => SecureRandom.uuid, 'evidence_scope' => scope,
      'attempt_id' => SecureRandom.uuid, 'state' => 'attempt_completed' }
  end

  after { clients.each(&:close) }

  it 'uses native object identity without invoking application equality overrides' do
    client = sdk
    error = raised_error
    reads = 0
    error.define_singleton_method(:equal?) do |_other|
      reads += 1
      raise 'host equality'
    end
    client.with_operation_context(kind: 'request') do
      client.capture_exception(error)
      client.capture_exception(error)
    end
    client.flush
    expect(reads).to eq(0)
    expect(calls.length).to eq(2)
  end

  [false, true].each do |drop_first|
    it "retains repeated native records and a report after hook rejection (#{drop_first})" do
      count = 0
      hook = lambda do |event|
        count += 1
        count == 1 ? nil : event
      end
      client = sdk(before_send: drop_first ? hook : nil)
      error = raised_error
      client.with_operation_context(kind: 'request') do
        client.capture_exception(error, context: { logger_name: 'synthetic' })
        client.flush
        client.capture_exception(error, context: drop_first ? {} : { logger_name: 'synthetic' })
        client.flush
      end
      expect(calls.length).to eq(drop_first ? 1 : 2)
    end
  end

  it 'preserves native logged exceptions and their causes as one exception event' do
    require 'stringio'
    client = sdk(evidence_capabilities: pin)
    logger = Logger.new(StringIO.new)
    client.capture_logger(logger)
    logger.error(raised_error)
    logger.error('ordinary error')
    client.flush
    expect(calls.map { |event| event['event_type'] }).to eq(%w[backend_exception log_event])
    expect(calls.first['payload']['exception_evidence']['nodes'].map do |node|
      node['message']
    end).to include('outer', 'inner')
  end

  it 'retains the SemanticLogger native exception rather than its generic message' do
    client = sdk(evidence_capabilities: pin)
    record = Struct.new(:message, :level, :name, :exception, :payload, :tags)
                   .new('operation failed', :error, 'synthetic', raised_error, {}, [])
    DebugBundle::Logging::SemanticLoggerAppender.new(client: client).log(record)
    client.flush
    expect(calls.map { |event| event['event_type'] }).to eq(['backend_exception'])
    expect(calls.first['context']['log_message']).to eq('operation failed')
    expect(calls.first['payload']['exception_evidence']['nodes'].length).to eq(2)
  end

  it 'deduplicates logger and middleware identity within each owned request only' do
    require 'stringio'
    client = sdk
    logger = Logger.new(StringIO.new)
    client.capture_logger(logger)
    error = raised_error
    2.times do
      client.with_operation_context(kind: 'request') do
        logger.error(error)
        client.capture_exception(error)
      end
    end
    client.flush
    expect(calls.length).to eq(2)
  end

  it 'retains legacy exception fields until the entire destination supports enrichment' do
    [nil, pin].each do |proof|
      client = sdk(evidence_capabilities: proof)
      client.capture_exception(raised_error)
      client.flush
      event = calls.last
      expect(schema.valid?(event)).to be(true), schema_errors(event)
      expect(event['payload'].key?('exception_evidence')).to eq(!proof.nil?)
      expect(event['payload']['message']).to eq('outer')
      expect(event['payload']['runtime']['framework_extras']['engine']).to eq(RUBY_ENGINE)
      expect(event['context']['causes'].first['message']).to eq('inner')
    end
  end

  it 'accepts idiomatic Ruby capability options without retaining a mutable pin' do
    client = sdk(evidence_capabilities: { version: 1, features: [:exception_evidence_v1] })
    client.capture_exception(raised_error)
    client.flush
    expect(calls.last['payload']).to have_key('exception_evidence')
    expect { client.config.evidence_capabilities['features'].clear }.to raise_error(FrozenError)
  end

  it 'keeps manually constructed exceptions canonical without fabricating a thrown trace' do
    client = sdk(evidence_capabilities: pin)
    client.capture_exception(RuntimeError.new(''))
    client.flush
    expect(schema.valid?(calls.last)).to be(true), schema_errors(calls.last)
    expect(calls.last['payload']['exception_evidence']['nodes'][0]).to include(
      'trace_origin' => 'unavailable', 'frames' => []
    )
  end

  it 'tracks nested operations without changing block results or error propagation' do
    client = sdk(evidence_capabilities: pin, capture_recovery_observations: true)
    result = client.with_operation_context(kind: 'job', name: 'invoice.calculate', limit_ms: 5000) do
      client.capture_exception(raised_error, context: { failure_ref: SecureRandom.uuid })
      42
    end
    expect(result).to eq(42)
    client.flush
    failure = calls.last
    expect(failure['payload']['execution']).to include('kind' => 'job', 'name' => 'invoice.calculate',
                                                       'limit_ms' => 5000)
    expect(failure['payload']['execution']['elapsed_ms']).to be >= 0
    reference = failure['context']['evidence_reference']
    client.capture_recovery(observation(scope: reference['scope']).merge('failure_ref' => reference['failure_ref']))
    client.flush
    expect(calls.last['event_type']).to eq('diagnostic_context')
    expect(schema.valid?(calls.last)).to be(true)
    expect do
      client.with_operation_context(kind: 'command') { raise ArgumentError, 'original' }
    end.to raise_error(ArgumentError, 'original')
    client.capture_exception(raised_error)
    client.flush
    expect(calls.last['payload']).not_to have_key('execution')
  end

  it 'requires the independent local recovery opt-in, proof and capture policy' do
    client = sdk(evidence_capabilities: pin)
    client.capture_recovery(observation)
    expect(client.buffered_event_count).to eq(0)
    client = sdk(capture_recovery_observations: true)
    client.capture_recovery(observation)
    expect(client.buffered_event_count).to eq(0)
    client = sdk(evidence_capabilities: pin, capture_recovery_observations: true)
    client.instance_variable_set(:@capture_policy, DebugBundle::RemoteConfig.minimal_capture_policy)
    client.capture_recovery(observation)
    expect(client.buffered_event_count).to eq(0)
  end

  it 'keeps startup diagnostics off until asynchronous server policy permits them' do
    entered = Queue.new
    release = Queue.new
    fetcher = lambda do |_etag|
      entered << true
      release.pop
      { status_code: 200, body: { 'capture_policy' => { 'preset' => 'balanced' },
                                  'evidence_capabilities' => pin } }
    end
    client = sdk(config_fetcher: fetcher, evidence_capabilities: pin, capture_recovery_observations: true)
    Timeout.timeout(2) { entered.pop }
    input = observation
    client.capture_recovery(input)
    expect(client.buffered_event_count).to eq(0)
    client.capture_exception(raised_error)
    expect(client.buffered_event_count).to eq(1)
    release << true
    Timeout.timeout(2) { sleep(0.005) until client.instance_variable_get(:@capture_policy).preset == 'balanced' }
    client.capture_recovery(input)
    client.flush
    expect(calls.map { |event| event['event_type'] }).to eq(%w[backend_exception diagnostic_context])
  ensure
    release << true
  end

  it 'does not inherit an operation in another Fiber and revokes its scope on close' do
    client = sdk(evidence_capabilities: pin)
    client.with_operation_context(kind: 'request') do
      Fiber.new { client.capture_exception(raised_error) }.resume
      client.flush
      expect(calls.last['payload']).not_to have_key('execution')
      client.close
      expect(client.instance_variable_get(:@operations).snapshot).to be_nil
    end
  end

  it 'allows canonical hook UUID and event-type replacement while reapplying recovery policy' do
    replacement = '11111111-1111-7111-8111-111111111111'
    hook = lambda do |event|
      event['event_id'] = replacement
      event['event_type'] = 'diagnostic_context'
      event['payload'] = DebugBundle::EvidenceWire.recovery(observation)
      event
    end
    client = sdk(evidence_capabilities: pin, before_send: hook)
    client.capture_exception(raised_error)
    client.flush
    expect(calls).to be_empty
    client = sdk(evidence_capabilities: pin, capture_recovery_observations: true, before_send: hook)
    client.capture_exception(raised_error)
    client.flush
    expect(calls.last).to include('event_id' => replacement, 'event_type' => 'diagnostic_context')
  end

  it 'uses the smaller native hook budget and bypasses beforeSend for the fatal path' do
    hook_calls = []
    client = sdk(evidence_capabilities: pin, before_send: lambda { |event|
      hook_calls << event
      event
    })
    client.__send__(:capture_exception_internal, raised_error, context: nil, handled: false, run_before_send: false)
    client.flush
    graph = calls.last['payload']['exception_evidence']
    expect(graph['nodes'].length).to be <= 2
    expect(JSON.generate(graph).bytesize).to be <= 4096
    expect(hook_calls).to be_empty
  end

  it 'keeps finalized recovery retries owned once when the hook changes identity' do
    sent = []
    attempts = 0
    now = Time.now.utc
    transport = lambda do |request|
      attempts += 1
      sent.concat(request[:events])
      DebugBundle::Transport::Result.new(status_code: attempts == 1 ? 503 : 202)
    end
    replacement = SecureRandom.uuid
    hook_calls = 0
    client = sdk(transport: transport, time_provider: -> { now }, evidence_capabilities: pin,
                 capture_recovery_observations: true, before_send: lambda do |event|
                   hook_calls += 1
                   event.merge('event_id' => replacement)
                 end)
    client.capture_recovery(observation)
    client.flush
    bytes = client.instance_variable_get(:@buffer_bytes)
    client.flush
    expect(client.instance_variable_get(:@buffer_bytes)).to eq(0)
    expect(bytes).to be > 0
    expect(sent.map { |event| event['event_id'] }).to eq([replacement, replacement])
    expect(hook_calls).to eq(1)
    expect(client.instance_variable_get(:@diagnostics).instance_variable_get(:@pending)).to be_empty
  end

  it 'does not grant proof from a malformed ACK and discovers it on an acknowledged existing send' do
    proof = pin
    replies = [
      { 'accepted' => 99, 'rejected' => 0, 'errors' => [], 'evidence_capabilities' => proof },
      { 'accepted' => 1, 'rejected' => 0, 'errors' => [], 'evidence_capabilities' => proof }
    ]
    now = Time.now.utc
    transport = ->(_request) { DebugBundle::Transport::Result.new(status_code: 202, body: replies.shift) }
    client = sdk(transport: transport, time_provider: -> { now })
    client.capture_exception(raised_error)
    client.flush
    expect(client.instance_variable_get(:@evidence).supports?('exception_evidence_v1')).to be(false)
    now += 2
    client.flush
    expect(client.instance_variable_get(:@evidence).supports?('exception_evidence_v1')).to be(true)
  end

  it 'downgrades a rejected optional addition once without re-running the hook or changing its identity' do
    sent = []
    hooks = 0
    now = Time.now.utc
    transport = lambda do |request|
      event = request[:events].first
      sent << event
      body = if sent.length == 1
               { 'accepted' => 0, 'rejected' => 1, 'errors' => [{ 'index' => 0, 'reason' => 'invalid_event' }],
                 'evidence_capabilities' => { 'version' => 1, 'features' => [] } }
             else
               { 'accepted' => 1, 'rejected' => 0, 'errors' => [] }
             end
      DebugBundle::Transport::Result.new(status_code: 202, body: body)
    end
    client = sdk(transport: transport, time_provider: -> { now }, evidence_capabilities: pin,
                 before_send: lambda { |event|
                   hooks += 1
                   event
                 })
    client.capture_exception(raised_error)
    client.flush
    now += 2
    client.flush
    expect(sent.length).to eq(2)
    expect(sent[0]['payload']).to have_key('exception_evidence')
    expect(sent[1]['payload']).not_to have_key('exception_evidence')
    expect(sent[1]['event_id']).to eq(sent[0]['event_id'])
    expect(sent[1]['payload']['message']).to eq('outer')
    expect(hooks).to eq(1)
  end

  it 'preserves the primary error when mandatory privacy makes optional evidence invalid' do
    client = sdk(evidence_capabilities: pin, redact_fields: ['classification'])
    client.capture_exception(raised_error)
    client.flush
    expect(calls.last['payload']['message']).to eq('outer')
    expect(calls.last['payload']).not_to have_key('exception_evidence')
    expect(schema.valid?(calls.last)).to be(true)
  end

  it 'does not grant capabilities from invalid config while retaining legacy config parsing' do
    fetcher = lambda { |_etag|
      { status_code: 200, body: { 'capture_policy' => 'invalid', 'evidence_capabilities' => pin } }
    }
    client = sdk(config_fetcher: fetcher, evidence_capabilities: pin)
    client.refresh_remote_config!
    expect(client.instance_variable_get(:@evidence).supports?('exception_evidence_v1')).to be(false)
    expect(client.instance_variable_get(:@capture_policy).preset).to eq('balanced')
  end

  it 'discards queued diagnostics on close and cannot capture into a stopped sender' do
    client = sdk(evidence_capabilities: pin, capture_recovery_observations: true)
    client.capture_recovery(observation)
    expect(client.buffered_event_count).to eq(1)
    client.close
    expect(client.buffered_event_count).to eq(0)
    expect(client.instance_variable_get(:@diagnostics).accounted_bytes).to eq(0)
    client.capture_exception(raised_error)
    client.capture_recovery(observation)
    expect(client.buffered_event_count).to eq(0)
  end

  it 'retains in-flight ownership until completion when close races a send' do
    started = Queue.new
    gate = Queue.new
    transport = lambda do |_request|
      started << true
      gate.pop
      DebugBundle::Transport::Result.new(status_code: 503)
    end
    client = sdk(transport: transport, batch_size: 1, evidence_capabilities: pin,
                 capture_recovery_observations: true)
    client.capture_recovery(observation)
    Timeout.timeout(2) { started.pop }
    client.close
    expect(client.instance_variable_get(:@buffer_bytes)).to be > 0
    gate << true
    Timeout.timeout(2) { sleep 0.005 until client.buffered_event_count.zero? }
    expect(client.instance_variable_get(:@buffer_bytes)).to eq(0)
    expect(client.instance_variable_get(:@diagnostics).accounted_bytes).to eq(0)
  ensure
    gate << true if gate
  end

  it 'permanently disposes the previous singleton project when init replaces it' do
    previous = DebugBundle.instance_variable_get(:@client)
    old = sdk(evidence_capabilities: pin)
    DebugBundle.client = old
    old.with_operation_context(kind: 'request') do
      current = DebugBundle.init(project_token: 'new-project', batch_size: 1000, flush_interval: 3600,
                                 transport: lambda { |request|
                                   calls.concat(request[:events])
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 })
      clients << current
      old.capture_exception(raised_error)
      old.instance_variable_set(:@owner_pid, Process.pid - 1)
      old.capture_exception(raised_error)
      expect(old.buffered_event_count).to eq(0)
      current.capture_exception(raised_error)
      current.flush
      expect(calls.last['project_token']).to eq('new-project')
      expect(calls.last['payload']).not_to have_key('execution')
    end
  ensure
    DebugBundle.client = previous
  end
end
