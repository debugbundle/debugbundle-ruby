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
        'request' => {}, 'response' => {}, 'runtime' => {}, 'probe_data' => {}
      },
      'request_event' => {
        'method' => 'GET', 'path' => '/', 'query' => {}, 'headers' => {},
        'response_status' => 503, 'duration_ms' => 10, 'response_headers' => {}
      },
      'frontend_breadcrumb' => { 'breadcrumb_type' => 'navigation', 'data' => {} },
      'frontend_exception' => {
        'name' => 'Error', 'message' => 'failure', 'stack' => 'stack',
        'breadcrumbs' => [], 'probe_data' => {}
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

  it 'covers strict scalar helpers used by request, suppression, and probe validation' do
    expect(described_class.non_negative_number?(Float::INFINITY)).to be(false)
    expect(described_class.non_negative_integer?(-1)).to be(false)
    expect(described_class.positive_integer?(0)).to be(false)
    expect(described_class.timestamp?('invalid')).to be(false)
    expect(described_class.nullable_uuid?('invalid')).to be(false)
  end
end
