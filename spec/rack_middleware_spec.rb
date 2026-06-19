# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'json'
require 'openssl'

RSpec.describe DebugBundle::Rack::Middleware do
  let(:transport_events) { [] }
  let(:client) do
    transport = Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(transport_events)

    config_fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'rack-etag',
        body: {
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'all',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      service: 'checkout-api',
      transport: transport,
      config_fetcher: config_fetcher
    )
  end

  it 'captures request metadata and preserves the response' do
    app = lambda do |_env|
      [201, { 'Content-Type' => 'application/json', 'Set-Cookie' => 'secret' }, ['ok']]
    end

    middleware = described_class.new(app, client: client)
    status, headers, body = middleware.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/checkout',
      'QUERY_STRING' => 'cart_id=123',
      'HTTP_X_REQUEST_ID' => 'req-1',
      'HTTP_X_DEBUGBUNDLE_TRACE_ID' => 'trace-1',
      'HTTP_AUTHORIZATION' => 'Bearer secret',
      'HTTP_USER_AGENT' => 'RSpec'
    )

    client.flush
    event = transport_events.fetch(0).fetch(:events).fetch(0)

    expect(status).to eq(201)
    expect(headers).to include('Content-Type' => 'application/json')
    expect(body).to eq(['ok'])
    expect(event.fetch('event_type')).to eq('request_event')
    expect(event.fetch('correlation')).to include('request_id' => 'req-1', 'trace_id' => 'trace-1')
    expect(event.fetch('payload').fetch('headers')).to include('user-agent' => 'RSpec')
    expect(event.fetch('payload').fetch('headers')).not_to have_key('authorization')
    expect(event.fetch('payload').fetch('response_headers')).to include('content-type' => 'application/json')
    expect(event.fetch('payload').fetch('response_headers')).not_to have_key('set-cookie')
  end

  it 'captures exceptions and re-raises them' do
    app = lambda do |_env|
      raise 'checkout failure'
    end

    middleware = described_class.new(app, client: client)

    expect do
      middleware.call(
        'REQUEST_METHOD' => 'GET',
        'PATH_INFO' => '/checkout',
        'QUERY_STRING' => '',
        'HTTP_X_REQUEST_ID' => 'req-2'
      )
    end.to raise_error(RuntimeError, 'checkout failure')

    client.flush
    event = transport_events.fetch(0).fetch(:events).fetch(0)

    expect(event.fetch('event_type')).to eq('backend_exception')
    expect(event.fetch('payload')).to include('handled' => false)
    expect(event.fetch('correlation')).to include('request_id' => 'req-2')
  end

  it 'activates trigger-token probe shipping for a single request' do
    trigger_key = 'trigger-secret'
    expires_at = (Time.now.utc + 60).iso8601
    payload_json = JSON.generate(
      activation_id: 'probe-1',
      label_pattern: 'checkout.*',
      service: '*',
      environment: '*',
      trigger_expires_at: expires_at
    )
    payload_segment = Base64.urlsafe_encode64(payload_json, padding: false)
    signature = OpenSSL::HMAC.digest('sha256', trigger_key, payload_segment)
    token = "dbundle_probe_#{payload_segment}.#{Base64.urlsafe_encode64(signature, padding: false)}"

    transport = Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(transport_events)

    config_fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'rack-trigger-etag',
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          trigger_token_key: trigger_key,
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'all',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    trigger_client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      service: 'checkout-api',
      transport: transport,
      config_fetcher: config_fetcher
    )

    app = lambda do |_env|
      trigger_client.probe('checkout.tax', { region: 'us-east-1' })
      [200, { 'Content-Type' => 'application/json' }, ['ok']]
    end

    middleware = described_class.new(app, client: trigger_client)
    middleware.call(
      'REQUEST_METHOD' => 'GET',
      'PATH_INFO' => '/checkout',
      'QUERY_STRING' => '',
      'HTTP_X_DEBUGBUNDLE_PROBE_TRIGGER' => token,
      'HTTP_X_REQUEST_ID' => 'req-trigger'
    )

    trigger_client.flush
    events = transport_events.fetch(0).fetch(:events)
    probe_event = events.find { |entry| entry.fetch('event_type') == 'probe_event' }

    expect(probe_event).not_to be_nil
    expect(probe_event.fetch('payload')).to include(
      'label' => 'checkout.tax',
      'activation_id' => 'probe-1',
      'probe_label_pattern' => 'checkout.*'
    )
  end

  it 'captures Rails route, controller, and action metadata when present' do
    app = lambda do |_env|
      [422, { 'Content-Type' => 'application/json' }, ['invalid']]
    end

    middleware = described_class.new(app, client: client)
    middleware.call(
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO' => '/patients/123/checkouts',
      'QUERY_STRING' => '',
      'action_dispatch.request_id' => 'req-rails',
      'action_dispatch.route_uri_pattern' => '/patients/:patient_id/checkouts',
      'action_dispatch.request.parameters' => {
        'controller' => 'checkouts',
        'action' => 'create'
      }
    )

    client.flush
    event = transport_events.fetch(0).fetch(:events).fetch(0)
    payload = event.fetch('payload')
    context = event.fetch('context')

    expect(payload).to include(
      'route_template' => '/patients/:patient_id/checkouts'
    )
    expect(context).to include(
      'controller' => 'checkouts',
      'action' => 'create'
    )
  end
end
