# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::RemoteConfig do
  it 'matches directives by expiry, scope, exact labels, wildcard labels, and prefixes' do
    now = Time.iso8601('2026-07-27T08:00:00Z')
    directive = described_class::Directive.new(
      id: 'directive',
      label_pattern: 'checkout.*',
      service: 'checkout',
      environment: '*',
      expires_at: now + 60
    )

    expect(directive.active?(label: 'checkout', service: 'checkout', environment: 'test', now: now)).to be(true)
    expect(directive.active?(label: 'checkout.total', service: 'checkout', environment: 'test', now: now)).to be(true)
    expect(directive.active?(label: 'cart.total', service: 'checkout', environment: 'test', now: now)).to be(false)
    expect(directive.active?(label: 'checkout.total', service: 'orders', environment: 'test', now: now)).to be(false)
    expect(
      directive.active?(label: 'checkout.total', service: 'checkout', environment: 'test', now: now + 61)
    ).to be(false)

    wildcard = directive.dup
    wildcard.label_pattern = '*'
    wildcard.service = '*'
    expect(wildcard.active?(label: 'anything', service: 'orders', environment: 'test', now: now)).to be(true)
  end

  it 'parses policy, probe directives, polling, and symbol-key fallbacks' do
    snapshot = described_class.parse(
      {
        probes_enabled: false,
        remote_probes_enabled: true,
        poll_interval_ms: 500,
        trigger_token_key: 'key',
        capture_policy: {
          preset: 'investigative',
          immediate_client_error_statuses: [409, '422'],
          immediate_client_error_path_rules: [
            { status_code: 422, path_pattern: '/checkout/*', methods: %w[post POST] }
          ]
        },
        active_probes: [
          {
            id: 'directive',
            label_pattern: 'checkout.*',
            expires_at: '2026-07-27T09:00:00Z'
          },
          { id: 'invalid', expires_at: 'invalid' }
        ]
      },
      60
    )

    expect(snapshot.probes_enabled).to be(false)
    expect(snapshot.remote_probes_enabled).to be(true)
    expect(snapshot.poll_interval_seconds).to eq(1)
    expect(snapshot.directives.length).to eq(1)
    expect(snapshot.capture_policy.immediate_client_error_statuses).to eq([409])
    expect(snapshot.capture_policy.immediate_client_error_path_rules.first.http_methods).to eq(['POST'])
  end

  it 'rejects malformed directives and path-rule bounds' do
    expect(described_class.parse(nil, 60)).to be_nil
    expect(described_class.parse_capture_policy(nil)).to be_nil
    expect(described_class.parse_directive(nil)).to be_nil
    expect(described_class.parse_time(nil)).to be_nil
    expect(described_class.parse_time('bad')).to be_nil
    expect(described_class.valid_path_pattern?('relative')).to be(false)
    expect(described_class.valid_path_pattern?('/path?query')).to be(false)
    expect(described_class.valid_path_pattern?('/bad/*/suffix')).to be(false)
    expect(described_class.parse_immediate_client_error_path_rules(Array.new(26, {}))).to eq([])
    expect(
      described_class.parse_immediate_client_error_path_rules(
        [{ status_code: 500, path_pattern: '/bad', methods: ['TRACE'] }]
      )
    ).to eq([])
  end
end
