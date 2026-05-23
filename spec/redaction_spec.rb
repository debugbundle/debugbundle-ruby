# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::Redaction::Redactor do
  it 'redacts segment-aware sensitive keys' do
    redacted = described_class.new.redact_value(
      {
        'user_password' => 'super-secret',
        'apiKey' => 'abc123',
        'sessionId' => 'sess-1',
        'safe' => { 'message' => 'ok' }
      }
    )

    expect(redacted).to include(
      'user_password' => '[REDACTED]',
      'apiKey' => '[REDACTED]',
      'sessionId' => '[REDACTED]'
    )
    expect(redacted.fetch('safe')).to eq({ 'message' => 'ok' })
  end

  it 'protects against circular references' do
    value = {}
    value['self'] = value

    redacted = described_class.new.redact_value(value)

    expect(redacted.fetch('self')).to eq('[Circular]')
  end

  it 'supports additional sensitive fields from framework configuration' do
    redactor = described_class.new(
      sensitive_fields: DebugBundle::Redaction::DEFAULT_SENSITIVE_FIELDS + %w[patient_notes]
    )

    redacted = redactor.redact_value('patient_notes' => 'diagnosis details', 'safe' => 'ok')

    expect(redacted).to include('patient_notes' => '[REDACTED]', 'safe' => 'ok')
  end
end
