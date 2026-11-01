# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::BeforeSend do
  let(:base_event) do
    {
      'schema_version' => '2026-03-01',
      'event_id' => '11111111-1111-4111-8111-111111111111',
      'event_type' => 'log_event',
      'occurred_at' => '2026-07-27T08:00:00Z',
      'sdk_name' => '@debugbundle/sdk-ruby',
      'sdk_version' => '1.3.0',
      'service' => { 'name' => 'ruby-test', 'environment' => 'test' },
      'payload' => { 'level' => 'error', 'message' => 'failure', 'attributes' => {} }
    }
  end

  it 'validates every closed canonical payload variant' do
    payloads = {
      'backend_exception' => {
        'name' => 'RuntimeError', 'message' => 'failure', 'stack' => 'stack', 'handled' => true,
        'request' => { 'method' => 'UNKNOWN', 'path' => '/', 'query' => {}, 'headers' => {} },
        'response' => { 'status_code' => 0 }, 'runtime' => { 'version' => 'fixture' },
        'probe_data' => { 'version' => 1, 'items' => [] }
      },
      'request_event' => {
        'method' => 'GET', 'path' => '/', 'query' => {}, 'headers' => {},
        'response_status' => 503, 'duration_ms' => 10, 'response_headers' => {}
      },
      'frontend_breadcrumb' => { 'breadcrumb_type' => 'route_change', 'data' => {} },
      'frontend_exception' => {
        'name' => 'Error', 'message' => 'failure', 'stack' => 'stack',
        'browser' => { 'name' => 'fixture', 'version' => '1' },
        'breadcrumbs' => [], 'probe_data' => { 'version' => 1, 'items' => [] }
      },
      'deploy_metadata' => {
        'commit_sha' => 'abc', 'version' => '1', 'branch' => 'main',
        'environment' => 'test', 'deployed_at' => '2026-07-27T08:00:00Z'
      },
      'error_suppressed' => {
        'fingerprint' => 'fp', 'suppressed_count' => 2, 'window_seconds' => 60,
        'first_seen' => '2026-07-27T08:00:00Z', 'last_seen' => '2026-07-27T08:01:00Z'
      },
      'probe_event' => {
        'label' => 'cart.total', 'data' => { 'value' => 2 },
        'activation_id' => nil, 'probe_label_pattern' => 'cart.*'
      }
    }

    payloads.each do |event_type, payload|
      event = base_event.merge('event_type' => event_type, 'payload' => payload)
      expect(described_class.valid?(event)).to be_truthy, event_type
      expect(described_class.valid_identity?(event)).to be_truthy, event_type
      expect(described_class.valid_payload_shape?(event_type, payload)).to be_truthy, event_type
    end
  end

  it 'retains the structural helper API while canonical validation rejects additional fields' do
    expect(described_class.valid_payload_shape?('log_event', base_event['payload'])).to be(true)
    expect(described_class.valid_payload_shape?('unknown', {})).to be(false)
    recovery = JSON.parse(File.read(File.join(__dir__, 'fixtures/evidence-wire-cases.json')))
                   .fetch('events').find { |fixture| fixture['id'] == 'operation_recovery' }.fetch('event')
    expect(described_class.valid_payload_shape?('diagnostic_context', recovery['payload'])).to be_truthy
    expect(described_class.valid_identity?(base_event.merge('event_id' => 'invalid'))).to be_falsey
    expect(described_class.valid_backend_exception?({})).to be(false)
    expect(described_class.valid_request_event?({})).to be(false)
  end

  it 'enforces conditional browser and mobile identity after schema validation' do
    event = base_event.merge('event_type' => 'frontend_exception', 'payload' => {
                               'name' => 'Error', 'message' => 'failure', 'stack' => 'stack'
                             })
    expect(described_class.valid?(event)).to be(false)
    browser = event.merge('payload' => event['payload'].merge('browser' => { 'name' => 'fixture', 'version' => '1' }))
    expect(described_class.valid?(browser)).to be(true)
    described_class::MOBILE_SDK_NAMES.each do |name|
      expect(described_class.valid?(browser.merge('sdk_name' => name))).to be(false)
    end
  end

  it 'rejects malformed roots, timestamps, payload fields, and typed values' do
    expect(described_class.valid?([])).to be(false)
    expect(described_class.valid?(base_event.merge('unexpected' => true))).to be(false)
    expect(described_class.valid?(base_event.merge('event_id' => 'not-a-uuid'))).to be(false)
    expect(described_class.valid?(base_event.merge('occurred_at' => 'not-a-time'))).to be(false)
    expect(
      described_class.valid?(
        base_event.merge('payload' => base_event['payload'].merge('unexpected' => true))
      )
    ).to be(false)
    expect(described_class.valid?(base_event.merge('event_type' => 'unknown'))).to be_falsey
  end

  it 'rejects malformed fields throughout the closed canonical envelope' do
    invalid = [
      base_event.merge('context' => 'not an object'),
      base_event.merge('correlation' => { 'unknown' => 'field' }),
      base_event.merge('project_token' => 1),
      base_event.merge('service' => base_event['service'].merge('runtime' => 1)),
      base_event.merge('service' => base_event['service'].merge('unknown' => 'field')),
      base_event.merge('payload' => base_event['payload'].merge('level' => 1)),
      base_event.merge('event_type' => 'frontend_breadcrumb',
                       'payload' => { 'breadcrumb_type' => 'navigation', 'data' => {} }),
      base_event.merge('event_type' => 'backend_exception', 'payload' => {
                         'name' => 'Error', 'message' => 'failure', 'stack' => 'stack', 'handled' => true,
                         'request' => {}, 'response' => {}, 'runtime' => {}
                       })
    ]
    invalid.each { |event| expect(described_class.valid?(event)).to be(false), event.inspect }
  end

  it 'retains schema-allowed arbitrary nonempty log levels and native symbol object keys' do
    event = base_event.merge('payload' => base_event['payload'].merge('level' => 'custom-level'),
                             'context' => { application_key: 'value' })
    result = described_class.apply(base_event, ->(_original) { event })
    expect(result['payload']['level']).to eq('custom-level')
    expect(result['context']).to eq('application_key' => 'value')
  end

  JSON.parse(File.read(File.join(__dir__, 'fixtures/evidence-wire-cases.json'))).fetch('events').each do |fixture|
    it "validates the complete canonical corpus envelope: #{fixture.fetch('id')}" do
      expect(described_class.valid?(fixture.fetch('event'))).to eq(fixture.fetch('valid'))
    end
  end

  it 'never invokes an application Hash accessor while validating a returned hook value' do
    calls = []
    returned = base_event.dup
    returned.define_singleton_method(:keys) do
      calls << :keys
      raise 'must not inspect through application accessors'
    end
    replacement = described_class.apply(base_event, ->(_event) { returned })
    expect(replacement).to eq(base_event)
    expect(calls).to eq([])
  end

  it 'covers strict scalar helpers used by request, suppression, and probe validation' do
    expect(described_class.non_negative_number?(Float::INFINITY)).to be(false)
    expect(described_class.non_negative_integer?(-1)).to be(false)
    expect(described_class.positive_integer?(0)).to be(false)
    expect(described_class.timestamp?('invalid')).to be(false)
    expect(described_class.nullable_uuid?('invalid')).to be(false)
  end
end
