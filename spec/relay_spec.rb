# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'
require 'tmpdir'

RSpec.describe DebugBundle::Relay::Handler do
  let(:browser_event) do
    {
      'schema_version' => '2026-03-01',
      'event_id' => 'evt_1',
      'event_type' => 'frontend_exception',
      'sdk_version' => '0.1.0',
      'occurred_at' => Time.now.utc.iso8601,
      'project_token' => 'browser-token',
      'organization_id' => 'org_1',
      'sdk_name' => 'spoofed',
      'service' => {
        'name' => 'checkout-web',
        'environment' => 'production'
      },
      'correlation' => {
        'trace_id' => 'trace-1',
        'request_id' => 'req-1',
        'session_id' => nil,
        'user_id_hash' => 'user-1'
      },
      'payload' => { 'message' => 'boom' }
    }
  end

  it 'validates, sanitizes, and writes local-only relay batches' do
    Dir.mktmpdir do |directory|
      handler = described_class.new(project_mode: :local_only, project_token: 'dbundle_proj_server',
                                    local_events_dir: directory)
      response = handler.handle(
        method: 'POST',
        headers: {
          'host' => 'app.example.com',
          'origin' => 'https://app.example.com',
          'content-type' => 'application/json'
        },
        body: JSON.generate('batch' => [browser_event]),
        ip_address: '127.0.0.1'
      )

      expect(response.status).to eq(202)

      file_name = Dir.children(directory).find { |entry| entry.end_with?('.events.json') }
      parsed = JSON.parse(File.read(File.join(directory, file_name)))
      event = parsed.fetch(0)

      expect(event).to include('sdk_name' => '@debugbundle/sdk-browser', 'project_token' => 'dbundle_proj_server')
      expect(event).not_to have_key('organization_id')
      expect(event.fetch('correlation')).to include('trace_id' => 'trace-1', 'request_id' => 'req-1')
    end
  end

  it 'rejects wrong origins' do
    handler = described_class.new(project_mode: :local_only, project_token: 'dbundle_proj_server')
    response = handler.handle(
      method: 'POST',
      headers: {
        'host' => 'app.example.com',
        'origin' => 'https://evil.example.com',
        'content-type' => 'application/json'
      },
      body: JSON.generate('batch' => [browser_event]),
      ip_address: '127.0.0.1'
    )

    expect(response.status).to eq(403)
  end

  it 'supports a shared rate-limit store interface' do
    Dir.mktmpdir do |directory|
      store = Class.new do
        attr_reader :writes

        def initialize
          @counts = Hash.new(0)
          @writes = []
        end

        def increment(key, amount, expires_in:)
          @writes << [key, expires_in]
          @counts[key] += amount
        end
      end.new

      handler = described_class.new(
        project_mode: :local_only,
        project_token: 'dbundle_proj_server',
        local_events_dir: directory,
        rate_limit_per_minute: 1,
        rate_limit_store: store
      )

      request = {
        method: 'POST',
        headers: {
          'host' => 'app.example.com',
          'origin' => 'https://app.example.com',
          'content-type' => 'application/json'
        },
        body: JSON.generate('batch' => [browser_event]),
        ip_address: '127.0.0.1'
      }

      expect(handler.handle(request).status).to eq(202)
      expect(handler.handle(request).status).to eq(429)
      expect(store.writes.length).to eq(2)
    end
  end

  it 'writes durable spool files and forwards connected events' do
    Dir.mktmpdir do |directory|
      forwarded = []
      transport = Class.new do
        define_method(:initialize) do |forwarded|
          @forwarded = forwarded
        end

        define_method(:call) do |request|
          @forwarded << request
          DebugBundle::Transport::Result.new(status_code: 202)
        end
      end.new(forwarded)

      handler = described_class.new(
        project_mode: :connected,
        project_token: 'dbundle_proj_server',
        spool_dir: directory,
        forward_transport: transport
      )

      response = handler.handle(
        method: 'POST',
        headers: {
          'host' => 'app.example.com',
          'origin' => 'https://app.example.com',
          'content-type' => 'application/json'
        },
        body: JSON.generate('batch' => [browser_event]),
        ip_address: '127.0.0.1'
      )

      expect(response.status).to eq(202)
      expect(Dir.children(directory).any? { |entry| entry.end_with?('.events.json') }).to be(true)
      expect(forwarded.length).to eq(1)
      expect(forwarded.fetch(0).fetch(:project_token)).to eq('dbundle_proj_server')
    end
  end

  it 'exposes a Rack relay adapter' do
    Dir.mktmpdir do |directory|
      middleware = DebugBundle::Rack::RelayMiddleware.new(
        nil,
        handler: described_class.new(project_mode: :local_only, project_token: 'dbundle_proj_server',
                                     local_events_dir: directory)
      )

      status, headers, body = middleware.call(
        'REQUEST_METHOD' => 'POST',
        'HTTP_HOST' => 'app.example.com',
        'HTTP_ORIGIN' => 'https://app.example.com',
        'CONTENT_TYPE' => 'application/json',
        'REMOTE_ADDR' => '127.0.0.1',
        'rack.input' => StringIO.new(JSON.generate('batch' => [browser_event]))
      )

      expect(status).to eq(202)
      expect(headers).to include('Content-Type' => 'application/json')
      expect(JSON.parse(body.fetch(0))).to include('accepted' => 1)
    end
  end
end
