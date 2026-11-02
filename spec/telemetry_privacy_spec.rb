# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe DebugBundle::TelemetryPrivacy do
  it 'checks identity values without masking identity field names' do
    expect(described_class.safe_event_identity?({ 'correlation' => { 'session_id' => 'session-123' } })).to be(true)
    unsafe = { 'correlation' => { 'trace_id' => 'dbundle_proj_SYNTHETIC_SECRET' } }
    expect(described_class.safe_event_identity?(unsafe)).to be(false)
    expect(described_class.safe_event_identity?({ 'sdk_version' => 'password=SYNTHETIC_SECRET' })).to be(false)
  end

  it 'matches the shared portable privacy corpus' do
    fixture = JSON.parse(File.read(File.expand_path('../tests/fixtures/privacy-conformance.json', __dir__)))
    expect(fixture.fetch('policy')).to eq('telemetry-privacy-v1')
    fixture.fetch('cases').each do |entry|
      expect(described_class.protect(entry.fetch('input'))).to eq(entry.fetch('expected')), entry.fetch('id')
    end
  end

  it 'keeps additional keys additive and does not modify caller data' do
    input = { 'password' => 'SYNTHETIC_SECRET', 'tenant_pin_code' => 123, 'status' => 503 }
    safe = described_class.protect(input, additional_fields: ['tenant_pin_code'])
    expect(safe).to eq('password' => '[REDACTED]', 'tenant_pin_code' => '[REDACTED]', 'status' => 503)
    expect(described_class.protect(safe, additional_fields: ['tenant_pin_code'])).to eq(safe)
    expect(input.fetch('password')).to eq('SYNTHETIC_SECRET')
  end

  it 'redacts multiple assignment names in one text while retaining ordinary words' do
    text = 'password=alpha token=beta tenant_pin_code=gamma status=ok'

    expect(described_class.protect(text, additional_fields: ['tenant_pin_code'])).to eq(
      'password=[REDACTED] token=[REDACTED] tenant_pin_code=[REDACTED] status=ok'
    )
  end

  it 'redacts every mandatory assignment label without consuming adjacent text' do
    DebugBundle::TelemetryPrivacy::FIELDS.each do |field|
      expect(described_class.protect("before #{field}=synthetic after")).to eq(
        "before #{field}=[REDACTED] after"
      ), field
    end
  end

  it 'checks repeated frame keys once per bounded projection without sharing output ownership' do
    frames = Array.new(48) { { 'classification' => 'unknown', 'file' => 'app/job.rb', 'user_token' => 'synthetic' } }
    allow(described_class).to receive(:sensitive_key?).and_call_original
    allow(described_class).to receive(:scrub_text).and_call_original

    protected = described_class.protect(frames)

    expect(protected).to all(eq('classification' => 'unknown', 'file' => 'app/job.rb', 'user_token' => '[REDACTED]'))
    expect(described_class).to have_received(:sensitive_key?).with('classification', anything).once
    expect(described_class).to have_received(:scrub_text).with('classification', anything).once
    expect(described_class).to have_received(:scrub_text).with('unknown', anything).once
    expect(described_class).to have_received(:scrub_text).with('app/job.rb', anything).once
    protected.first['file'].replace('changed')
    expect(protected.last['file']).to eq('app/job.rb')
    expect(frames.first['file']).to eq('app/job.rb')
  end

  it 'isolates repeated-key decisions between custom privacy policies' do
    input = Array.new(4) { { 'tenant_code' => 'synthetic', 'user_token' => 'synthetic' } }

    expect(described_class.protect(input).first.fetch('tenant_code')).to eq('synthetic')
    expect(described_class.protect(input, additional_fields: ['tenant_code'])).to all(
      eq('tenant_code' => '[REDACTED]', 'user_token' => '[REDACTED]')
    )
    expect(described_class.protect(input).first.fetch('tenant_code')).to eq('synthetic')
  end

  it 'still protects new keys after a projection fills its repeated-key cache' do
    allow(described_class).to receive(:sensitive_key?).and_call_original
    input = [Array.new(256) { |index| ["field_#{index}", 'safe'] }.to_h,
             { 'field_256' => 'safe', 'nested_access_token' => 'synthetic',
               'password=synthetic' => 'withheld' },
             { 'field_256' => 'safe', 'nested_access_token' => 'synthetic' }]

    protected = described_class.protect(input)
    expected = { 'field_256' => 'safe', 'nested_access_token' => '[REDACTED]' }
    expect(protected.last(2)).to all(eq(expected))
    expect(described_class).to have_received(:sensitive_key?).with('field_256', anything).twice
  end

  it 'charges every repeated key and value against the projection byte budget' do
    input = Array.new(20) { { 'same_field' => 'x' * 16_384 } }

    expect { described_class.protect(input) }.to raise_error(ArgumentError, 'budget_exceeded')
  end

  it 'bounds short-text reuse and keeps redaction dependent on the current policy' do
    allow(described_class).to receive(:scrub_text).and_call_original
    input = Array.new(256) { |index| "safe-#{index}" } + %w[new-safe new-safe]
    # Keep each array within the existing 256-element collection limit.
    expect(described_class.protect([input.first(256), input.last(2)]).last).to eq(%w[new-safe new-safe])
    expect(described_class).to have_received(:scrub_text).with('new-safe', anything).twice
    expect(described_class.protect(['tenant_code=synthetic'])).to eq(['tenant_code=synthetic'])
    expect(described_class.protect(['tenant_code=synthetic'], additional_fields: ['tenant_code'])).to eq(
      ['tenant_code=[REDACTED]']
    )
    expect(described_class.protect(['token=synthetic', 'token=synthetic'])).to eq(
      ['token=[REDACTED]', 'token=[REDACTED]']
    )
  end
end
