# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'

RSpec.describe DebugBundle::Rails::RelayEndpoint do
  let(:relay_options_class) do
    Struct.new(
      :project_mode,
      :project_token,
      :service,
      :environment,
      :relay_durable_write,
      :relay_allowed_origins,
      :relay_forward_transport,
      :relay_rate_limit_per_minute,
      :relay_handler,
      keyword_init: true
    )
  end
  let(:app_config_class) { Struct.new(:debugbundle, keyword_init: true) }
  let(:fake_app_class) { Struct.new(:config, keyword_init: true) }

  it 'builds a relay handler from Rails config and forwards browser events' do
    transport_events = []
    forward_transport = Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(transport_events)

    app = fake_app_class.new(
      config: app_config_class.new(
        debugbundle: relay_options_class.new(
          project_mode: :connected,
          project_token: 'dbundle_proj_test',
          service: 'rails-checkout',
          environment: 'production',
          relay_durable_write: false,
          relay_allowed_origins: ['https://app.example.com'],
          relay_forward_transport: forward_transport,
          relay_rate_limit_per_minute: 10
        )
      )
    )

    endpoint = described_class.new(app: app)
    status, headers, body = endpoint.call(
      'REQUEST_METHOD' => 'POST',
      'CONTENT_TYPE' => 'application/json',
      'HOST' => 'app.example.com',
      'HTTP_ORIGIN' => 'https://app.example.com',
      'rack.input' => StringIO.new(
        JSON.generate(
          'batch' => [
            {
              'schema_version' => '2026-03-01',
              'event_id' => 'evt-1',
              'event_type' => 'frontend_exception',
              'sdk_name' => '@debugbundle/sdk-browser',
              'sdk_version' => '0.1.0',
              'occurred_at' => Time.now.utc.iso8601,
              'service' => { 'name' => 'browser-app', 'environment' => 'production' },
              'correlation' => { 'trace_id' => 'trace-1' },
              'payload' => { 'message' => 'boom' }
            }
          ]
        )
      )
    )

    expect(status).to eq(202)
    expect(headers).to include('Content-Type' => 'application/json')
    expect(JSON.parse(body.join)).to include('accepted' => 1, 'rejected' => 0)
    expect(transport_events.fetch(0).fetch(:events).fetch(0).fetch('service')).to include(
      'name' => 'rails-checkout',
      'environment' => 'production'
    )
  end

  it 'uses an explicit relay handler override when provided' do
    custom_handler = Class.new do
      attr_reader :requests

      def initialize
        @requests = []
      end

      def handle(request)
        @requests << request
        DebugBundle::Relay::Response.new(status: 202, body: { 'accepted' => 0, 'rejected' => 0, 'errors' => [] })
      end
    end.new

    app = fake_app_class.new(
      config: app_config_class.new(
        debugbundle: relay_options_class.new(
          relay_handler: custom_handler
        )
      )
    )

    endpoint = described_class.new(app: app)
    status, = endpoint.call(
      'REQUEST_METHOD' => 'POST',
      'CONTENT_TYPE' => 'application/json',
      'HOST' => 'example.com',
      'HTTP_ORIGIN' => 'https://example.com',
      'rack.input' => StringIO.new('{"batch":[]}')
    )

    expect(status).to eq(202)
    expect(custom_handler.requests.fetch(0)).to include(method: 'POST')
  end
end
