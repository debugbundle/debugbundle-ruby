# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'json'
require 'openssl'

RSpec.describe 'remote config and capture policy' do
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

  it 'drops logs below the server-owned capture policy' do
    fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'etag-1',
        body: {
          capture_policy: {
            preset: 'minimal',
            capture_logs: 'error',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'local_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      config_fetcher: fetcher,
      log_level: :info
    )

    client.capture_log('info message', level: :info)
    client.capture_log('error message', level: :error)
    client.flush

    events = transport_events.fetch(0).fetch(:events)
    expect(events.length).to eq(1)
    expect(events.fetch(0).fetch('payload')).to include('message' => 'error message')
  end

  it 'captures configured immediate client error request events even when the preset is minimal' do
    fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'etag-2',
        body: {
          capture_policy: {
            preset: 'minimal',
            capture_logs: 'error',
            capture_request_events: 'off',
            capture_breadcrumbs: 'local_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: [422]
          }
        }
      }
    end

    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport, config_fetcher: fetcher)
    client.capture_request({ method: 'POST', path: '/checkout', headers: {} }, { status_code: 422, headers: {} })
    client.flush

    event = transport_events.fetch(0).fetch(:events).fetch(0)
    expect(event.fetch('event_type')).to eq('request_event')
    expect(event.fetch('payload')).to include('response_status' => 422)
  end

  it 'ships standalone probe events when a remote directive matches' do
    fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'etag-3',
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          active_probes: [
            {
              id: 'probe-1',
              label_pattern: 'checkout.*',
              service: '*',
              environment: '*',
              expires_at: (Time.now.utc + 60).iso8601
            }
          ],
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'standalone_when_activated',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport, config_fetcher: fetcher)
    client.probe('checkout.tax', { region: 'us-east-1' })
    client.flush

    event = transport_events.fetch(0).fetch(:events).find { |entry| entry.fetch('event_type') == 'probe_event' }
    expect(event).not_to be_nil
    expect(event.fetch('payload')).to include(
      'label' => 'checkout.tax',
      'activation_id' => 'probe-1',
      'probe_label_pattern' => 'checkout.*'
    )
  end

  it 'keeps heavy probes dormant unless a remote directive matches' do
    active_fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'etag-heavy-active',
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          active_probes: [
            {
              id: 'probe-heavy-1',
              label_pattern: 'checkout.*',
              service: '*',
              environment: '*',
              expires_at: (Time.now.utc + 60).iso8601
            }
          ],
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'standalone_when_activated',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    dormant_fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'etag-heavy-dormant',
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          active_probes: [],
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'standalone_when_activated',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    active_calls = 0
    dormant_calls = 0

    active_client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      config_fetcher: lambda do |etag|
        active_calls += 1
        active_fetcher.call(etag)
      end
    )
    dormant_client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      config_fetcher: lambda do |etag|
        dormant_calls += 1
        dormant_fetcher.call(etag)
      end
    )

    active_probe_data = nil
    active_client.probe('checkout.tax', heavy: true) do
      active_probe_data = { region: 'us-east-1' }
    end

    dormant_probe_called = false
    dormant_client.probe('checkout.tax', heavy: true) do
      dormant_probe_called = true
      { region: 'us-east-1' }
    end

    active_client.flush

    probe_event = transport_events.fetch(0).fetch(:events).find { |entry| entry.fetch('event_type') == 'probe_event' }
    expect(active_calls).to eq(1)
    expect(dormant_calls).to eq(1)
    expect(active_probe_data).to eq({ region: 'us-east-1' })
    expect(dormant_probe_called).to be(false)
    expect(probe_event).not_to be_nil
    expect(probe_event.fetch('payload')).to include(
      'label' => 'checkout.tax',
      'data' => { 'region' => 'us-east-1' },
      'activation_id' => 'probe-heavy-1'
    )
  end

  it 'only ships trigger-token probe directives when remote policy is buffer-only' do
    trigger_key = 'trigger-secret'
    payload_json = JSON.generate(
      activation_id: 'trigger-1',
      label_pattern: 'checkout.*',
      service: '*',
      environment: '*',
      trigger_expires_at: (Time.now.utc + 60).iso8601
    )
    payload_segment = Base64.urlsafe_encode64(payload_json, padding: false)
    signature = OpenSSL::HMAC.digest('sha256', trigger_key, payload_segment)
    token = "dbundle_probe_#{payload_segment}.#{Base64.urlsafe_encode64(signature, padding: false)}"

    fetcher = lambda do |_etag|
      {
        status_code: 200,
        etag: 'etag-trigger-buffer-only',
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          trigger_token_key: trigger_key,
          active_probes: [
            {
              id: 'remote-1',
              label_pattern: 'checkout.*',
              service: '*',
              environment: '*',
              expires_at: (Time.now.utc + 60).iso8601
            }
          ],
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport, config_fetcher: fetcher)
    client.with_request_trigger(headers: { 'x-debugbundle-probe-trigger' => token }, query: {}) do
      client.probe('checkout.tax', { region: 'us-east-1' })
    end
    client.flush

    probe_events = transport_events.fetch(0).fetch(:events).select do |entry|
      entry.fetch('event_type') == 'probe_event'
    end
    activation_ids = probe_events.map { |event| event.fetch('payload').fetch('activation_id') }

    expect(activation_ids).to eq(['trigger-1'])
  end

  it 'refreshes the paid-tier config on the polling interval during client activity' do
    current_time = Time.utc(2026, 5, 23, 12, 0, 0)
    time_provider = -> { current_time }
    calls = 0
    fetcher = lambda do |_etag|
      calls += 1

      capture_logs = calls == 1 ? 'info' : 'error'
      {
        status_code: 200,
        etag: "etag-#{calls}",
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          poll_interval_ms: 1000,
          capture_policy: {
            preset: 'balanced',
            capture_logs: capture_logs,
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      config_fetcher: fetcher,
      time_provider: time_provider,
      log_level: :info
    )

    client.capture_log('first info', level: :info)
    current_time += 2
    client.capture_log('second info', level: :info)
    client.flush

    events = transport_events.fetch(0).fetch(:events)
    expect(calls).to eq(2)
    expect(events.map { |event| event.fetch('payload').fetch('message') }).to eq(['first info'])
  end

  it 'retries remote config polling after startup failure on the next interval' do
    current_time = Time.utc(2026, 5, 23, 12, 0, 0)
    time_provider = -> { current_time }
    calls = 0
    fetcher = lambda do |_etag|
      calls += 1
      return { status_code: 500 } if calls == 1

      {
        status_code: 200,
        etag: 'etag-recovered',
        body: {
          probes_enabled: true,
          remote_probes_enabled: true,
          poll_interval_ms: 1000,
          capture_policy: {
            preset: 'minimal',
            capture_logs: 'error',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'local_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      config_fetcher: fetcher,
      time_provider: time_provider,
      log_level: :info
    )

    current_time += 61
    client.capture_log('recovered info', level: :info)

    expect(calls).to eq(2)
    expect(client.buffered_event_count).to eq(0)
  end

  it 'does not continue polling after the server marks the project free tier' do
    current_time = Time.utc(2026, 5, 23, 12, 0, 0)
    time_provider = -> { current_time }
    calls = 0
    fetcher = lambda do |_etag|
      calls += 1
      {
        status_code: 200,
        etag: 'etag-free',
        body: {
          probes_enabled: true,
          remote_probes_enabled: false,
          capture_policy: {
            preset: 'balanced',
            capture_logs: 'warning',
            capture_request_events: 'failures_only',
            capture_breadcrumbs: 'exception_only',
            capture_probe_events: 'buffer_only',
            immediate_client_error_statuses: []
          }
        }
      }
    end

    client = DebugBundle::Client.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      config_fetcher: fetcher,
      time_provider: time_provider
    )

    current_time += 120
    client.capture_log('warning event', level: :warning)
    client.flush

    expect(calls).to eq(1)
    expect(transport_events.fetch(0).fetch(:events).fetch(0).fetch('payload')).to include('message' => 'warning event')
  end
end
