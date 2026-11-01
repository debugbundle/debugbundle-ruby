# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::CanonicalEventSchema do
  it 'fails closed on unsupported contract keywords, types, formats and external references' do
    [{ 'unexpected' => true }, { 'type' => 'foreign' }, { 'format' => 'email' },
     { '$ref' => 'https://example.invalid/schema.json' }].each do |schema|
      expect { described_class.new(schema) }.to raise_error(ArgumentError)
    end
  end

  it 'resolves only local JSON pointers and enforces scalar and collection bounds' do
    schema = { 'properties' => { 'a/b' => { 'type' => 'integer', 'minimum' => 1, 'maximum' => 3 } },
               '$ref' => '#/properties/a~1b' }
    validator = described_class.new(schema)
    expect(validator.accepts?(2)).to be(true)
    [-1, 4, 1.5, '2', Float::INFINITY].each { |value| expect(validator.accepts?(value)).to be(false) }
    validator = described_class.new({ 'type' => 'array', 'minItems' => 1, 'maxItems' => 2,
                                      'items' => { 'type' => 'string', 'minLength' => 1, 'maxLength' => 3 } })
    expect(validator.accepts?(['one'])).to be(true)
    [[], ['four'], [''], %w[a b c]].each { |value| expect(validator.accepts?(value)).to be(false) }
  end

  it 'bounds recursive schemas without following remote references or raising into the host' do
    validator = described_class.new({ 'properties' => { 'child' => { '$ref' => '#/properties/child' } } })
    expect(validator.accepts?({ 'child' => {} })).to be(false)
  end
end
