# frozen_string_literal: true

require 'spec_helper'

begin
  require 'sidekiq'
rescue LoadError
  nil
end

if defined?(Sidekiq)
  RSpec.describe 'Sidekiq integration' do
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

    it 'registers and executes through the Sidekiq middleware chain' do
      client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport)
      chain = Sidekiq::Middleware::Chain.new
      job = {
        'class' => 'CheckoutWorker',
        'queue' => 'critical',
        'jid' => 'jid-chain-1',
        'retry_count' => 1,
        'args' => [{ 'charge_id' => 'ch_123' }],
        'trace_id' => 'trace-chain-1'
      }

      chain.add(DebugBundle::Sidekiq::ServerMiddleware, client: client)

      expect(chain.entries.map(&:klass)).to include(DebugBundle::Sidekiq::ServerMiddleware)
      expect do
        chain.invoke(Object.new, job, 'critical') do
          raise 'chain failure'
        end
      end.to raise_error(RuntimeError, 'chain failure')

      client.flush
      event = transport_events.fetch(0).fetch(:events).fetch(0)

      expect(event.fetch('event_type')).to eq('backend_exception')
      expect(event.fetch('correlation')).to include('trace_id' => 'trace-chain-1')
      expect(event.fetch('payload').fetch('context').fetch('job')).to include(
        'class' => 'CheckoutWorker',
        'queue' => 'critical',
        'jid' => 'jid-chain-1'
      )
    end
  end
else
  RSpec.describe 'Sidekiq integration' do
    it 'requires the sidekiq gem for integration validation' do
      skip 'sidekiq gem not installed'
    end
  end
end
