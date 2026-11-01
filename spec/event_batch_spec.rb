# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::EventBatch do
  let(:corpus) { JSON.parse(File.read(File.join(__dir__, 'fixtures/evidence-wire-cases.json'))) }

  it 'matches the receiving body budget and measures actual escaped UTF-8 JSON' do
    expect(described_class::MAX_BODY_BYTES).to eq(corpus.fetch('transport').fetch('max_body_bytes'))
    expect(described_class::MAX_EVENT_BYTES).to eq(corpus.fetch('transport').fetch('max_event_wire_bytes'))
    events = [{ 'value' => '\\' * 65_000 }, { 'value' => '💡' * 33_100 }]
    chunks = described_class.chunks(events)
    expect(chunks.flatten).to eq(events)
    expect(chunks.length).to eq(2)
    expect(chunks.map { |chunk| JSON.generate(events: chunk).bytesize }.max).to be <= described_class::MAX_BODY_BYTES
    expect { described_class.chunks([{ 'value' => 'x' * 262_144 }]) }.to raise_error(ArgumentError)
    expect(described_class.chunks([])).to eq([[]])
  end

  it 'drops only optional evidence when a primary still fits and preserves custom reference data' do
    event = Marshal.load(Marshal.dump(corpus['events'].find { |fixture| fixture['id'] == 'native_graph' }['event']))
    event['context'] = { 'data' => 'x' * 260_500, 'evidence_reference' => 'application-defined' }
    event['payload']['exception_evidence']['nodes'][0]['stack'] = 'x' * 2000
    fitted = described_class.fit(event)
    expect(fitted.dig('payload', 'message')).to eq(event.dig('payload', 'message'))
    expect(fitted.dig('context', 'evidence_reference')).to eq('application-defined')
    expect(fitted['payload']).not_to have_key('exception_evidence')
    expect(described_class.fit(nil)).to be_nil
    expect(described_class.fit({ 'payload' => { 'data' => 'x' * 262_144 } })).to be_nil
  end
end
