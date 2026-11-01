# frozen_string_literal: true

require 'spec_helper'
require 'debugbundle/diagnostic_budget'
require 'securerandom'

RSpec.describe DebugBundle::DiagnosticBudget do
  let(:budget) { described_class.new }
  let(:reference) do
    { 'version' => 1, 'failure_ref' => SecureRandom.uuid,
      'scope' => { 'kind' => 'operation', 'operation_id' => SecureRandom.uuid } }
  end
  let(:recovery) do
    reference.merge('kind' => 'recovery', 'attempt_id' => SecureRandom.uuid, 'state' => 'attempt_completed')
  end

  it 'limits attempts and observations without renewing expired pending ownership' do
    20.times { |index| expect(budget.reserve("event-#{index}", recovery, 500, 10)).to be(true) }
    expect(budget.reserve('excess', recovery, 500, 10)).to be(false)
    expect(budget.reserve('expired', recovery, 500, 311)).to be(false)
    budget.release((0...20).map { |index| "event-#{index}" })
    expect(budget.accounted_bytes).to be < 1000
    5.times do |index|
      payload = recovery.merge('attempt_id' => SecureRandom.uuid)
      expect(budget.reserve("new-#{index}", payload, 500, 312)).to be(true)
    end
    expect(budget.reserve('sixth', recovery.merge('attempt_id' => SecureRandom.uuid), 500, 312)).to be(false)
    expect(budget.accounted_bytes).to be <= 65_536
  end

  it 'counts scope metadata in the same finite byte budget and rejects invalid sizes' do
    expect(budget.reserve('oversize', recovery, 65_536, 0)).to be(false)
    [-1, 65_537, nil].each { |size| expect(budget.reserve('invalid', recovery, size, 0)).to be(false) }
    expect(budget.reserve('invalid-clock', recovery, 500, Float::INFINITY)).to be(false)
    expect(budget.reserve('normal', recovery, 500, 0)).to be(true)
    expect(budget.reserve('normal', recovery, 500, 0)).to be(false)
    expect(budget.adjust('normal', 65_536)).to be(false)
    expect(budget.adjust('normal', 600)).to be(true)
    expect(budget.accounted_bytes).to be_between(600, 65_536)
    expect(budget.adjust('missing', 100)).to be(false)
  end

  it 'bounds failure windows and discards only expired windows without held observations' do
    50.times do
      expect(budget.register_failure(reference.merge('failure_ref' => SecureRandom.uuid), SecureRandom.uuid,
                                     0)).to be(true)
    end
    expect(budget.register_failure(reference, 'new', 0)).to be(false)
    expect(budget.reserve('new', recovery, 500, 0)).to be(false)
    expect(budget.register_failure(reference, 'new', 301)).to be(true)
    expect(budget.register_failure(reference, 'new', Float::NAN)).to be(false)
    expect(budget.accounted_bytes).to be < 1000
  end

  it 'fails closed on ambiguous failure identities and drops only its own pending receipt' do
    expect(budget.reserve('pending', recovery, 500, 0)).to be(true)
    expect(budget.register_failure(reference, 'first', 0)).to be(true)
    expect(budget.register_failure(reference, 'second', 0)).to be(false)
    expect(budget.eligible('pending', recovery)).to be(false)
    expect(budget.replace('pending', 'replacement', recovery, 500, 1)).to be(false)
    expect(budget.reserve('later', recovery, 500, 1)).to be(false)
    expect(budget.instance_variable_get(:@pending)).to be_empty
  end

  it 'preserves another receipt on a hook ID collision and accounts for changed identities and scopes' do
    other = recovery.merge('failure_ref' => SecureRandom.uuid)
    expect(budget.reserve('first', recovery, 500, 0)).to be(true)
    expect(budget.reserve('second', other, 500, 0)).to be(true)
    expect(budget.replace('first', 'second', recovery, 500, 1)).to be(false)
    expect(budget.eligible('second', other)).to be(true)
    expect(budget.replace('second', 'changed-longer-id', other, 600, 1)).to be(true)
    expect(budget.replace('changed-longer-id', 'moved', recovery, 700, 1)).to be(true)
    expect(budget.eligible('moved', recovery)).to be(true)
    budget.release(['moved', 'missing', nil])
    expect(budget.instance_variable_get(:@pending)).to be_empty
  end

  it 'allows only one coalesced passive context within its known failure window' do
    failure_id = SecureRandom.uuid
    payload = reference.merge('kind' => 'resource_observation', 'source_event_id' => failure_id)
    expect(budget.reserve('unknown', payload, 500, 0)).to be(false)
    expect(budget.register_failure(reference, failure_id, 0)).to be(true)
    expect(budget.reserve('late', payload, 500, 31)).to be(false)
    expect(budget.reserve('wrong', payload.merge('source_event_id' => SecureRandom.uuid), 500, 1)).to be(false)
    expect(budget.reserve('passive', payload, 500, 1)).to be(true)
    expect(budget.reserve('duplicate', payload, 500, 2)).to be(false)
    expect(budget.eligible('passive', payload)).to be(true)
    budget.release(['passive'])
    expect(budget.reserve('ack-cannot-renew', payload, 500, 3)).to be(false)
  end
end
