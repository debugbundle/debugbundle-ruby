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
end
