# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::Suppression::Tracker do
  it 'allows the first three identical events and then suppresses' do
    tracker = described_class.new

    captures = 5.times.map { |index| tracker.should_capture('same-error', now: index.to_f) }
    aggregates = tracker.drain_aggregates(now: 5.0)

    expect(captures).to eq([true, true, true, false, false])
    expect(aggregates.length).to eq(1)
    expect(aggregates.fetch(0)).to include('suppressed_count' => 2)
  end

  it 'bounds distinct fingerprints without losing admission for a new exception' do
    tracker = described_class.new

    2_100.times { |index| expect(tracker.should_capture("error-#{index}", now: index.to_f)).to be(true) }

    expect(tracker.instance_variable_get(:@states).length).to be <= 2_048
  end
end
