# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'

RSpec.describe DebugBundle::Relay::Handler do
  let(:corpus) { JSON.parse(File.read(File.join(__dir__, 'fixtures/evidence-wire-cases.json'))) }
  let(:event) do
    Marshal.load(Marshal.dump(corpus['events'].find do |fixture|
      fixture['id'] == 'native_graph'
    end['event']))
  end
  let(:recovery) do
    value = Marshal.load(Marshal.dump(corpus['events'].find do |fixture|
      fixture['id'] == 'operation_recovery'
    end['event']))
    value['event_id'] = '66666666-6666-4666-8666-666666666666'
    value
  end
  let(:pin) { { 'version' => 1, 'features' => DebugBundle::EvidenceWire::FEATURES } }

  def request(events, discover: true)
    { method: 'POST', url: discover ? '/debugbundle/browser?debugbundle_evidence=1' : '/debugbundle/browser',
      headers: { 'host' => 'app.example.test', 'origin' => 'https://app.example.test',
                 'content-type' => 'application/json' },
      body: JSON.generate('batch' => events), ip_address: '127.0.0.1' }
  end

  it 'bounds downstream bodies after server metadata expansion and keeps a partial spool pending' do
    Dir.mktmpdir do |directory|
      sent = []
      forward = lambda do |request|
        sent << request[:events]
        DebugBundle::Transport::Result.new(status_code: sent.length == 1 ? 202 : 503,
                                           body: { 'accepted' => request[:events].length, 'rejected' => 0,
                                                   'errors' => [], 'evidence_capabilities' => pin })
      end
      handler = described_class.new(project_token: 't' * 8192, service: 'server-app',
                                    spool_dir: directory, forward_transport: forward, evidence_capabilities: pin)
      events = 2.times.map do
        value = Marshal.load(Marshal.dump(event))
        value['event_id'] = SecureRandom.uuid
        value['context'] = 63.times.to_h { |index| ["detail_#{index}", 'x' * 2000] }
        value
      end
      input = request(events)
      expect(input[:body].bytesize).to be <= 262_144
      expect(handler.handle(input).status).to eq(202)
      expect(sent.length).to eq(2)
      expect(sent.map { |chunk| JSON.generate(events: chunk).bytesize }.max).to be <= 262_144
      expect(sent.flatten.map { |value| value['event_id'] }).to eq(events.map { |value| value['event_id'] })
      expect(Dir.glob(File.join(directory, '*.events.json')).length).to eq(1)
      expect(Dir.glob(File.join(directory, '*.delivered'))).to be_empty
    end
  end

  it 'shares one monotonic native budget across expanded chunks' do
    elapsed = 0.0
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { elapsed }
    transport = DebugBundle::Transport::HttpTransport.new('https://example.invalid/v1/events')
    calls = 0
    allow(transport).to receive(:call) do |input|
      calls += 1
      elapsed = 6.0
      DebugBundle::Transport::Result.new(status_code: 202, body: {
                                           'accepted' => input[:events].length, 'rejected' => 0, 'errors' => [],
                                           'evidence_capabilities' => pin
                                         })
    end
    events = 2.times.map do
      value = Marshal.load(Marshal.dump(event))
      value['context'] = 63.times.to_h { |index| ["detail_#{index}", 'x' * 2000] }
      value
    end
    state = DebugBundle::EvidenceDelivery.new(pin)
    forwarder = DebugBundle::Relay::Forwarder.new(transport, 't' * 8192, state)
    expect(forwarder.send(events, discover: true)).to eq([false, false])
    expect(calls).to eq(1)
  end

  it 'preserves closed graph, passive, recovery and reference DTOs in qualified local files' do
    Dir.mktmpdir do |directory|
      handler = described_class.new(project_mode: :local_only, project_token: 'server-owned',
                                    local_events_dir: directory, evidence_capabilities: pin)
      event['context'] = { 'evidence_reference' => recovery['payload'].slice('version', 'failure_ref', 'scope') }
      event['project_token'] = 'browser-spoof'
      response = handler.handle(request([event, recovery]))
      expect(response.status).to eq(202)
      expect(response.body).to include('accepted' => 2, 'rejected' => 0, 'evidence_capabilities' => pin)
      stored = Dir.glob(File.join(directory, '*.events.json')).flat_map { |path| JSON.parse(File.read(path)) }
      expect(stored.first['payload']['exception_evidence']).to eq(event['payload']['exception_evidence'])
      expect(stored.first['context']).to eq(event['context'])
      expect(stored.last['payload']).to eq(recovery['payload'])
      expect(stored.map { |item| item['project_token'] }).to eq(%w[server-owned server-owned])
      expect(stored.map { |item| item['sdk_name'] }.uniq).to eq(['@debugbundle/sdk-browser'])
    end
  end

  it 'fails closed for an unknown path while preserving the original ordinary error' do
    Dir.mktmpdir do |directory|
      handler = described_class.new(project_mode: :local_only, project_token: 'server-owned',
                                    local_events_dir: directory)
      response = handler.handle(request([event, recovery]))
      expect(response.status).to eq(202)
      expect(response.body).to include('accepted' => 1, 'rejected' => 1,
                                       'evidence_errors' => [{ 'index' => 1, 'reason' => 'invalid_event' }],
                                       'evidence_capabilities' => { 'version' => 1, 'features' => [] })
      stored = JSON.parse(File.read(Dir.glob(File.join(directory, '*.events.json')).first))
      expect(stored.first['payload']).to include('message' => 'fictional failure')
      expect(stored.first['payload']).not_to have_key('exception_evidence')
    end
  end

  it 'preserves legacy rejection status/text while opting in to indexed partial acknowledgements' do
    Dir.mktmpdir do |directory|
      handler = described_class.new(project_mode: :local_only, local_events_dir: directory, evidence_capabilities: pin)
      bad = Marshal.load(Marshal.dump(event))
      bad['payload']['exception_evidence']['version'] = 2
      response = handler.handle(request([event, bad]))
      expect(response.status).to eq(202)
      expect(response.body['evidence_errors']).to eq([{ 'index' => 1, 'reason' => 'invalid_event' }])
      legacy = handler.handle(request([bad], discover: false))
      expect(legacy.status).to eq(400)
      expect(legacy.body['errors'].first).to include('batch[0]')
      expect(legacy.body).not_to have_key('evidence_capabilities')
    end
  end

  it 'marks a durable spool delivered only after a complete negotiated downstream ACK' do
    [1, 99].each do |accepted|
      Dir.mktmpdir do |directory|
        forward = lambda do |_request|
          DebugBundle::Transport::Result.new(status_code: 202,
                                             body: { 'accepted' => accepted,
                                                     'rejected' => 0, 'errors' => [], 'evidence_capabilities' => pin })
        end
        handler = described_class.new(project_token: 'server-owned', spool_dir: directory,
                                      forward_transport: forward, evidence_capabilities: pin)
        response = handler.handle(request([event]))
        expect(response.status).to eq(202)
        expect(Dir.glob(File.join(directory, '*.delivered')).length).to eq(accepted == 1 ? 1 : 0)
        expect(response.body['evidence_capabilities']['features']).to eq(accepted == 1 ? pin['features'] : [])
      end
    end
  end

  it 'bounds Rack body reads and forwards capability discovery to the handler' do
    handler = described_class.new(project_mode: :local_only, max_body_bytes: 128)
    input = StringIO.new('x' * 1024)
    status, = DebugBundle::Rack::RelayMiddleware.new(handler: handler).call(
      'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/debugbundle/browser', 'QUERY_STRING' => 'debugbundle_evidence=1',
      'HTTP_HOST' => 'app.example.test', 'HTTP_ORIGIN' => 'https://app.example.test',
      'CONTENT_TYPE' => 'application/json', 'rack.input' => input
    )
    expect(status).to eq(413)
    expect(input.pos).to eq(129)
  end

  it 'retries only an invalid enriched original after downgrade and marks only complete combined acceptance' do
    [1, 99].each do |retry_accepted|
      Dir.mktmpdir do |directory|
        sent = []
        forward = lambda do |request|
          sent << request[:events]
          body = if sent.length == 1
                   { 'accepted' => 1, 'rejected' => 1,
                     'errors' => [{ 'index' => 1, 'reason' => 'invalid_event' }],
                     'evidence_capabilities' => { 'version' => 1, 'features' => [] } }
                 else
                   { 'accepted' => retry_accepted, 'rejected' => 0, 'errors' => [] }
                 end
          DebugBundle::Transport::Result.new(status_code: 202, body: body)
        end
        handler = described_class.new(project_token: 'server-owned', spool_dir: directory,
                                      forward_transport: forward, evidence_capabilities: pin)
        legacy = DebugBundle::EvidenceWire.without_optional(event)
        enriched = event.merge('event_id' => '77777777-7777-4777-8777-777777777777')
        response = handler.handle(request([legacy, enriched]))
        expect(response.status).to eq(202)
        expect(sent.length).to eq(2)
        expect(sent.last.length).to eq(1)
        expect(sent.last.first['event_id']).to eq(enriched['event_id'])
        expect(sent.last.first['payload']).not_to have_key('exception_evidence')
        expect(Dir.glob(File.join(directory, '*.delivered')).length).to eq(retry_accepted == 1 ? 1 : 0)
      end
    end
  end

  it 'keeps failed forwarding durable and rejects a failed nondurable write' do
    Dir.mktmpdir do |directory|
      forward = ->(_request) { DebugBundle::Transport::Result.new(status_code: 503) }
      handler = described_class.new(project_token: 'server-owned', spool_dir: directory, forward_transport: forward)
      expect(handler.handle(request([event])).status).to eq(202)
      expect(Dir.glob(File.join(directory, '*.events.json')).length).to eq(1)
      expect(Dir.glob(File.join(directory, '*.delivered'))).to be_empty
      handler = described_class.new(project_token: 'server-owned', durable_write: false, forward_transport: forward)
      expect(handler.handle(request([event])).status).to eq(500)
      handler = described_class.new(project_mode: :local_only, local_events_dir: File.join(directory, '..', 'blocked'))
      expect(handler.handle(request([event])).status).to eq(500)
    end
  end

  it 'allows opt-in evidence headers during a same-origin preflight' do
    handler = described_class.new(project_mode: :local_only)
    input = request([])
    input[:method] = 'OPTIONS'
    input[:headers]['access-control-request-headers'] = 'content-type,x-debugbundle-evidence'
    response = handler.handle(input)
    expect(response.status).to eq(204)
    expect(response.headers['Access-Control-Allow-Headers']).to include('x-debugbundle-evidence')
  end
end
