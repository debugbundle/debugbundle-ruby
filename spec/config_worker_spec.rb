# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe DebugBundle::ConfigWorker do
  it 'coalesces wakeups on one poller and ignores wake after close' do
    calls = Queue.new
    worker = described_class.new(next_wait_seconds: -> {}) { calls << true }
    Timeout.timeout(2) { calls.pop }

    worker.wake
    Timeout.timeout(2) { calls.pop }
    worker.close

    expect { worker.wake }.not_to raise_error
    expect(calls).to be_empty
  ensure
    worker&.close
  end
end
