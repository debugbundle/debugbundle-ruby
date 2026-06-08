# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'rack/mock'

RSpec.describe 'Rack integration' do
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

  it 'captures request context in a real Rack builder stack' do
    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', service: 'rack-checkout', transport: transport)
    app = Rack::Builder.new do
      use DebugBundle::Rack::Middleware, client: client
      run ->(_env) { [503, { 'Content-Type' => 'text/plain' }, ['ok']] }
    end.to_app

    response = Rack::MockRequest.new(app).get(
      '/checkout?cart_id=123',
      'HTTP_X_REQUEST_ID' => 'req-rack',
      'HTTP_X_DEBUGBUNDLE_TRACE_ID' => 'trace-rack'
    )

    client.flush
    event = transport_events.fetch(0).fetch(:events).fetch(0)

    expect(response.status).to eq(503)
    expect(response.body).to eq('ok')
    expect(event.fetch('event_type')).to eq('request_event')
    expect(event.fetch('correlation')).to include('request_id' => 'req-rack', 'trace_id' => 'trace-rack')
    expect(event.fetch('payload')).to include('path' => '/checkout', 'method' => 'GET', 'response_status' => 503)
  end
end
