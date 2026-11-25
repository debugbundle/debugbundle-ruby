# frozen_string_literal: true

require 'spec_helper'
require 'securerandom'

RSpec.describe DebugBundle::EventPrivacy do
  let(:failure_ref) { '22222222-2222-4222-8222-222222222222' }
  let(:page_id) { '33333333-3333-4333-8333-333333333333' }

  def frontend_event(browser_event: nil, rejection_reason: nil, exception_evidence: nil,
                     resource_observations: nil, context: nil)
    payload = {
      'name' => 'ResourceLoadError',
      'message' => 'Script failed to load',
      'stack' => 'ResourceLoadError: Script failed to load',
      'browser' => { 'name' => 'Chrome', 'version' => '130' }
    }
    payload['browser_event'] = browser_event if browser_event
    payload['rejection_reason'] = rejection_reason if rejection_reason
    payload['exception_evidence'] = exception_evidence if exception_evidence
    payload['resource_observations'] = resource_observations if resource_observations
    event = {
      'schema_version' => '2026-03-01',
      'event_id' => '44444444-4444-4444-8444-444444444444',
      'event_type' => 'frontend_exception',
      'sdk_name' => '@debugbundle/sdk-browser',
      'sdk_version' => '2.1.0',
      'service' => { 'name' => 'web', 'runtime' => 'browser', 'framework' => nil, 'environment' => 'production' },
      'occurred_at' => '2026-11-24T00:00:00Z',
      'correlation' => { 'request_id' => nil, 'trace_id' => nil, 'session_id' => 'sess-123', 'user_id_hash' => nil },
      'payload' => payload
    }
    event['context'] = context if context
    event
  end

  def sample_browser_event(tag_name: 'script', attributes: { 'rel' => 'preload', 'as' => 'script', 'async' => true })
    {
      'kind' => 'resource_error',
      'message' => 'Failed with tag=SYNTHETIC_MSG',
      'file_name' => 'https://cdn.example.test/app.js?token=SYNTHETIC_TOK&tag=SYNTHETIC_TAG',
      'line_number' => 1,
      'column_number' => 2,
      'target' => {
        'tag_name' => tag_name,
        'source_url' => 'https://cdn.example.test/widget.js?tag=SYNTHETIC_Q',
        'attributes' => attributes
      },
      'page' => {
        'url' => 'https://app.example.test/checkout?tag=SYNTHETIC_PAGE',
        'referrer' => nil,
        'ready_state' => 'complete',
        'visibility_state' => 'visible'
      },
      'opaque' => true
    }
  end

  it 'preserves all 10 allowlisted HTML resource tags under broad redact_fields and redacts non-allowlisted tags' do
    %w[script link img audio video source iframe object embed input].each do |tag|
      event = frontend_event(browser_event: sample_browser_event(tag_name: tag.upcase))
      protected = described_class.protect(event, additional_fields: ['tag'])
      expect(protected.dig('payload', 'browser_event', 'target', 'tag_name')).to eq(tag.upcase)
      expect(JSON.generate(protected)).not_to include('SYNTHETIC_')
    end

    custom_tag_event = frontend_event(browser_event: sample_browser_event(tag_name: 'custom-secret'))
    protected_custom = described_class.protect(custom_tag_event, additional_fields: ['tag'])
    expect(protected_custom.dig('payload', 'browser_event', 'target', 'tag_name')).to eq('[REDACTED]')

    exact_tag_event = frontend_event(browser_event: sample_browser_event(tag_name: 'div'))
    protected_exact = described_class.protect(exact_tag_event, exact_fields: ['tag'])
    expect(protected_exact.dig('payload', 'browser_event', 'target', 'tag_name')).to eq('div')

    caller_redacted = frontend_event(browser_event: sample_browser_event(tag_name: '[REDACTED]'))
    protected_redacted = described_class.protect(caller_redacted, additional_fields: ['tag'])
    expect(protected_redacted.dig('payload', 'browser_event', 'target', 'tag_name')).to eq('[REDACTED]')
  end

  it 'scrubs browser stack URLs and frame URLs inside exception_evidence while preserving closed schema fields' do
    evidence = {
      'version' => 1,
      'runtime' => 'browser',
      'root_id' => 0,
      'nodes' => [
        {
          'id' => 0,
          'name' => 'ChunkLoadError',
          'message' => 'Failed reason=SYNTHETIC_REASON',
          'stack' => "ChunkLoadError\n    at load (https://user:pass@cdn.example.test/app.js?ordinary=private:12:4)",
          'trace_origin' => 'capture',
          'parsing_status' => 'parsed',
          'frames' => [
            {
              'function' => 'load',
              'file' => 'https://user:pass@cdn.example.test/app.js?ordinary=private',
              'line' => 12,
              'column' => 4,
              'classification' => 'application'
            }
          ],
          'relationships' => []
        }
      ],
      'truncated' => false,
      'unavailable_reason' => nil
    }
    frames = evidence['nodes'][0]['frames']
    frames << frames.first.merge('line' => 20)
    event = frontend_event(
      exception_evidence: evidence,
      context: {
        'evidence_reference' => { 'version' => 1, 'failure_ref' => failure_ref,
                                  'scope' => { 'kind' => 'page', 'page_id' => page_id } },
        'evidence_limits' => { 'version' => 1, 'execution' => 'unsupported' },
        'payout' => { 'file' => 'SYNTHETIC_FILE', 'reference' => 'SYNTHETIC_REF', 'reason' => 'SYNTHETIC_R' }
      }
    )

    protected = described_class.protect(event, additional_fields: %w[file reference reason classification])
    node = protected.dig('payload', 'exception_evidence', 'nodes', 0)
    expect(node['message']).to eq('Failed reason=[REDACTED]')
    expect(node['stack']).to eq("ChunkLoadError\n    at load (https://cdn.example.test/app.js:12:4)")
    expect(node['frames'][0]['file']).to eq('https://cdn.example.test/app.js')
    expect(node['frames'][0]['classification']).to eq('application')
    expect(node['frames'][1]).to eq(node['frames'][0].merge('line' => 20))
    expect(node['frames'][1]['file']).not_to equal(node['frames'][0]['file'])
    expect(protected.dig('context', 'evidence_reference', 'failure_ref')).to eq(failure_ref)
    expect(protected.dig('context', 'evidence_limits')).to eq('version' => 1, 'execution' => 'unsupported')
    expect(protected.dig('context', 'payout')).to eq(
      'file' => '[REDACTED]', 'reference' => '[REDACTED]', 'reason' => '[REDACTED]'
    )
    expect(JSON.generate(protected)).not_to include('private')
    expect(JSON.generate(protected)).not_to include('user:pass')
    expect(JSON.generate(protected)).not_to include('SYNTHETIC_')
  end

  it 'preserves diagnostic_context resource_observation and error_suppressed queue_pressure reason' do
    diag = {
      'schema_version' => '2026-03-01',
      'event_id' => '55555555-5555-4555-8555-555555555555',
      'event_type' => 'diagnostic_context',
      'sdk_name' => '@debugbundle/sdk-browser',
      'sdk_version' => '2.1.0',
      'service' => { 'name' => 'web', 'environment' => 'production' },
      'occurred_at' => '2026-11-24T00:00:00Z',
      'correlation' => { 'session_id' => 'sess-123' },
      'payload' => {
        'version' => 1,
        'kind' => 'resource_observation',
        'failure_ref' => failure_ref,
        'scope' => { 'kind' => 'page', 'page_id' => page_id },
        'source_event_id' => '44444444-4444-4444-8444-444444444444',
        'observations' => {
          'version' => 1,
          'items' => [
            {
              'kind' => 'csp',
              'observed_at' => '2026-11-24T00:00:00Z',
              'source_url' => 'https://cdn.example.test/assets/a.js',
              'effective_directive' => 'script-src',
              'disposition' => 'enforce',
              'document_status_code' => 200
            }
          ]
        }
      }
    }
    protected_diag = described_class.protect(diag, additional_fields: %w[tag reference scope])
    expect(protected_diag.dig('payload', 'failure_ref')).to eq(failure_ref)
    expect(protected_diag.dig('payload', 'observations', 'items', 0, 'source_url')).to eq(
      'https://cdn.example.test/assets/a.js'
    )

    suppressed = {
      'schema_version' => '2026-03-01',
      'event_id' => '66666666-6666-4666-8666-666666666666',
      'event_type' => 'error_suppressed',
      'sdk_name' => '@debugbundle/sdk-ruby',
      'sdk_version' => '2.1.4',
      'service' => { 'name' => 'api', 'environment' => 'production' },
      'occurred_at' => '2026-11-24T00:00:00Z',
      'correlation' => {},
      'payload' => {
        'fingerprint' => 'fp',
        'suppressed_count' => 3,
        'window_seconds' => 60,
        'first_seen' => '2026-11-24T00:00:00Z',
        'last_seen' => '2026-11-24T00:01:00Z',
        'reason' => 'queue_pressure',
        'level' => 'error'
      }
    }
    protected_suppressed = described_class.protect(suppressed, additional_fields: ['reason'])
    expect(protected_suppressed.dig('payload', 'reason')).to eq('queue_pressure')
  end

  it 'does not exempt spoofed or invalid protocol-named fields and fails closed on hostile objects' do
    spoofed = frontend_event(
      browser_event: sample_browser_event.merge('extra_secret' => 'SYNTHETIC_EXTRA'),
      rejection_reason: { 'kind' => 'invalid_kind', 'message' => 'SYNTHETIC_REJ' },
      context: {
        'evidence_reference' => { 'reference' => 'SYNTHETIC_FAKE_REF' },
        'evidence_limits' => { 'version' => 1, 'execution' => 'unsupported', 'extra' => 'SYNTHETIC_EXTRA' }
      }
    )
    protected = described_class.protect(spoofed, additional_fields: %w[tag reference reason extra])
    expect(protected.dig('context', 'evidence_reference')).to eq('[REDACTED]')
    expect(protected.dig('context', 'evidence_limits', 'extra')).to eq('[REDACTED]')
    expect(protected.dig('payload', 'browser_event', 'target', 'tag_name')).to eq('[REDACTED]')
    expect(protected.dig('payload', 'rejection_reason')).to eq('[REDACTED]')
    expect(JSON.generate(protected)).not_to include('SYNTHETIC_')

    calls = []
    hostile = Object.new
    %i[to_s to_str each keys [] is_a?].each do |name|
      hostile.define_singleton_method(name) { calls << name }
    end
    hostile_event = frontend_event(browser_event: sample_browser_event.merge('target' => hostile))
    expect(described_class.protect(hostile_event, additional_fields: ['tag'])).to be_nil
    expect(calls).to eq([])
  end

  it 'enforces the combined 256 KiB limit after re-assembling preserved protocol fields' do
    large_context = 17.times.to_h { |index| ["field_#{index}", 'x' * 15_000] }
    large_context['evidence_reference'] = {
      'version' => 1,
      'failure_ref' => failure_ref,
      'scope' => { 'kind' => 'page', 'page_id' => page_id }
    }
    event = frontend_event(
      browser_event: sample_browser_event.merge('message' => 'y' * 12_000),
      context: large_context
    )
    expect(described_class.protect(event)).to be_nil
  end
end
