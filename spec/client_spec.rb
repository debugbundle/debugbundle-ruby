# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

RSpec.describe DebugBundle::Client do
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

  it 'buffers and flushes canonical events' do
    client = described_class.new(
      project_token: 'dbundle_proj_test',
      service: 'checkout-api',
      environment: 'production',
      transport: transport
    )

    client.set_context(:account_id, 'acct_123')
    client.capture_log('payment retry failed', level: :error, context: { trace_id: 'trace-1' })

    expect(client.buffered_event_count).to eq(1)
    expect(client.flush).to be(true)
    expect(client.last_event_at).not_to be_nil

    payload = transport_events.fetch(0)
    event = payload.fetch(:events).fetch(0)

    expect(event.fetch('event_type')).to eq('log_event')
    expect(event.fetch('schema_version')).to eq('2026-03-01')
    expect(event.fetch('sdk_name')).to eq('@debugbundle/sdk-ruby')
    expect(event.fetch('service')).to include('name' => 'checkout-api', 'environment' => 'production')
    expect(event.fetch('correlation')).to include('trace_id' => 'trace-1')
    expect(event.fetch('payload')).to include('level' => 'error', 'message' => 'payment retry failed')
  end

  it 'captures explicit exception blocks and re-raises' do
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)

    expect do
      client.with_exception_capture(context: { request_id: 'req-1' }) do
        raise ArgumentError, 'invalid checkout'
      end
    end.to raise_error(ArgumentError, 'invalid checkout')

    client.flush
    event = transport_events.fetch(0).fetch(:events).fetch(0)
    expect(event.fetch('event_type')).to eq('backend_exception')
    expect(event.fetch('payload')).to include('handled' => false)
    expect(event.fetch('correlation')).to include('request_id' => 'req-1')
  end

  it 'registers at-exit capture once and flushes shutdown exceptions' do
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)
    registered_callback = nil

    allow(client).to receive(:at_exit) do |&block|
      registered_callback = block
    end

    expect(client.capture_exceptions).to be(true)
    expect(client.capture_at_exit).to be(false)
    expect(registered_callback).not_to be_nil

    begin
      raise 'shutdown boom'
    rescue RuntimeError
      registered_callback.call
    end

    event = transport_events.fetch(0).fetch(:events).fetch(0)
    expect(event.fetch('event_type')).to eq('backend_exception')
    expect(event.fetch('payload')).to include('handled' => false, 'message' => 'shutdown boom')
  end

  it 'captures unhandled thread exceptions after hooks are armed' do
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)

    allow(client).to receive(:at_exit)

    expect(client.capture_exceptions).to be(true)

    thread = Thread.new do
      raise 'thread boom'
    end

    expect { thread.value }.to raise_error(RuntimeError, 'thread boom')

    event = transport_events.fetch(0).fetch(:events).fetch(0)
    expect(event.fetch('event_type')).to eq('backend_exception')
    expect(event.fetch('payload')).to include('handled' => false, 'message' => 'thread boom')
  end

  it 'suppresses duplicate exceptions and emits an aggregate' do
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)
    error = RuntimeError.new('boom')
    error.set_backtrace(['app/models/checkout.rb:10'])

    5.times { client.capture_exception(error) }

    expect(client.buffered_event_count).to eq(3)
    client.flush

    flushed_events = transport_events.fetch(0).fetch(:events)
    expect(flushed_events.count { |event| event.fetch('event_type') == 'backend_exception' }).to eq(3)
    expect(flushed_events.count { |event| event.fetch('event_type') == 'error_suppressed' }).to eq(1)
  end

  it 'backs off after 429 responses without dropping buffered events' do
    retry_transport = Class.new do
      def initialize
        @calls = 0
      end

      def call(_request)
        @calls += 1
        return DebugBundle::Transport::Result.new(status_code: 429, retry_after_seconds: 1) if @calls == 1

        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new

    current_time = Time.utc(2026, 5, 23, 12, 0, 0)
    time_provider = -> { current_time }

    client = described_class.new(project_token: 'dbundle_proj_test', transport: retry_transport,
                                 time_provider: time_provider)
    client.capture_log('worker started', level: :warning)

    expect(client.flush).to be(false)
    expect(client.buffered_event_count).to eq(1)
    expect(client.status).to eq(:degraded)

    current_time += 2
    expect(client.flush).to be(true)
    expect(client.buffered_event_count).to eq(0)
  end

  it 'defaults development captures to secure local event files' do
    Dir.mktmpdir do |directory|
      client = described_class.new(project_token: 'dbundle_proj_test', local_events_dir: directory)

      client.capture_log('local event', level: :error)
      expect(client.flush).to be(true)

      file_name = Dir.children(directory).find { |entry| entry.end_with?('.events.json') }
      event = JSON.parse(File.read(File.join(directory, file_name))).fetch(0)

      expect(event.fetch('event_type')).to eq('log_event')
      expect(event.fetch('payload')).to include('message' => 'local event')
    end
  end

  it 'does not raise for invalid project mode configuration' do
    expect do
      described_class.new(project_token: 'dbundle_proj_test', project_mode: :surprising, transport: transport)
    end.not_to raise_error
  end

  it 'applies sample rate before buffering events' do
    client = described_class.new(
      project_token: 'dbundle_proj_test',
      transport: transport,
      sample_rate: 0.25,
      random_provider: -> { 0.9 }
    )

    client.capture_log('sampled out', level: :error)

    expect(client.buffered_event_count).to eq(0)
  end

  it 'does not include local OS account names in runtime facts' do
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)

    client.capture_exception(RuntimeError.new('privacy check'))
    client.flush

    runtime = transport_events.fetch(0).fetch(:events).fetch(0).fetch('payload').fetch('runtime')
    expect(runtime).not_to have_key('user')
  end

  it 'builds a default remote config fetcher for connected remote environments' do
    fetcher_instances = []
    fetcher_class = Class.new do
      define_method(:initialize) do |endpoint, project_token:, sdk_name:, sdk_version:|
        fetcher_instances << {
          endpoint: endpoint,
          project_token: project_token,
          sdk_name: sdk_name,
          sdk_version: sdk_version
        }
      end

      define_method(:call) do |_etag|
        {
          status_code: 200,
          etag: 'cfg-default',
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
    end

    stub_const('DebugBundle::Transport::HttpConfigFetcher', fetcher_class)

    client = described_class.new(project_token: 'dbundle_proj_test', environment: 'production')
    client.capture_log('warning dropped by default fetched policy', level: :warning)

    expect(fetcher_instances.fetch(0)).to include(
      endpoint: DebugBundle::Config::DEFAULT_ENDPOINT,
      project_token: 'dbundle_proj_test',
      sdk_name: '@debugbundle/sdk-ruby'
    )
    expect(client.buffered_event_count).to eq(0)
  end
end
