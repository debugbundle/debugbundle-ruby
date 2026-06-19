# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DebugBundle::Sidekiq::ServerMiddleware do
  let(:transport_events) { [] }
  let(:transport) do
    Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(transport_events)
  end

  it 'captures job exceptions and preserves retries by re-raising' do
    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport)
    middleware = described_class.new(client: client)
    job = {
      'class' => 'CheckoutWorker',
      'queue' => 'critical',
      'jid' => 'jid-1',
      'retry_count' => 2,
      'args' => [123, { 'charge_id' => 'ch_1' }],
      'trace_id' => 'trace-job-1'
    }

    expect do
      middleware.call(Object.new, job, 'critical') do
        raise 'worker failed'
      end
    end.to raise_error(RuntimeError, 'worker failed')

    client.flush
    event = transport_events.fetch(0).fetch(:events).fetch(0)

    expect(event.fetch('event_type')).to eq('backend_exception')
    expect(event.fetch('correlation')).to include('trace_id' => 'trace-job-1')
    expect(event.fetch('context').fetch('job')).to include(
      'class' => 'CheckoutWorker',
      'queue' => 'critical',
      'jid' => 'jid-1',
      'retry_count' => 2
    )
  end
end
