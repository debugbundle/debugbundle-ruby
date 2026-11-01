# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'debugbundle/evidence_wire'

RSpec.describe DebugBundle::EvidenceWire do
  corpus = JSON.parse(File.read(File.join(__dir__, 'fixtures/evidence-wire-cases.json')))

  corpus.fetch('events').each do |fixture|
    it "matches the accepting evidence contract: #{fixture.fetch('id')}" do
      expect(described_class.valid_optional?(fixture.fetch('event'))).to eq(fixture.fetch('valid'))
    end
  end

  corpus.fetch('capabilities').each do |fixture|
    it "matches capability proof: #{fixture.fetch('id')}" do
      expect(described_class.descriptor(fixture['input'])['features']).to eq(fixture['features'])
    end
  end

  corpus.fetch('json_sizes').each do |fixture|
    it "counts canonical JSON bytes for #{fixture['value'].inspect}" do
      expect(DebugBundle::EvidenceJson.bytes(fixture['value'])).to eq(fixture['bytes'])
    end
  end

  it 'rejects foreign DTOs without invoking formatting, enumeration or equality' do
    calls = []
    foreign = Object.new
    %i[to_s to_json each == hash nil? equal? is_a?].each do |name|
      foreign.define_singleton_method(name) { calls << name }
    end
    expect(described_class.descriptor(foreign)).to eq('version' => 1, 'features' => [])
    event = corpus.fetch('events').first.fetch('event')
    expect(described_class.valid_optional?(event.merge('payload' => { 'exception_evidence' => foreign }))).to be(false)
    expect(calls).to eq([])
  end

  it 'does not invoke a foreign class equality override during native type checks' do
    calls = []
    type = Class.new
    type.define_singleton_method(:equal?) do |_other|
      calls << :class_equality
      false
    end
    expect(DebugBundle::EvidenceValue.copy(type.new)).to equal(DebugBundle::EvidenceValue::INVALID)
    expect(calls).to eq([])
  end
end
