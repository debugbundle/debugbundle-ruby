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

  it 'redacts exact fields case-insensitively with punctuation significant while keeping mandatory keys broad' do
    redactor = described_class.new(exact_fields: ['tag', 'x-tag', 'token', /ignored/])

    redacted = redactor.redact_value(
      'tag' => 'SYNTHETIC_SECRET',
      'TAG' => 'SYNTHETIC_UPPER',
      'tag_name' => 'script',
      'tagName' => 'link',
      'tag-name' => 'img',
      'x-tag' => 'SYNTHETIC_HYPHEN',
      'X-TAG' => 'SYNTHETIC_HYPHEN_UPPER',
      'x_tag' => 'keep-underscore',
      'user_token' => 'SYNTHETIC_TOKEN',
      'ignored' => 'keep-non-string'
    )

    expect(redacted).to eq(
      'tag' => '[REDACTED]',
      'TAG' => '[REDACTED]',
      'tag_name' => 'script',
      'tagName' => 'link',
      'tag-name' => 'img',
      'x-tag' => '[REDACTED]',
      'X-TAG' => '[REDACTED]',
      'x_tag' => 'keep-underscore',
      'user_token' => '[REDACTED]',
      'ignored' => 'keep-non-string'
    )
  end
end
