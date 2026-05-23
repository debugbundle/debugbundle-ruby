# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'logger'
require 'rack/test'
require 'rails'
require 'debugbundle/rails'

RSpec.describe 'Rails Railtie integration' do
  include Rack::Test::Methods

  def app
    @app ||= build_rails_app
  end

  after do
    @app = nil
    DebugBundle.client = nil
    Rails.instance_variable_set(:@application, nil)
  end

  it 'mounts the configured relay route and forwards browser events' do
    post '/relay/browser',
         JSON.generate('batch' => [browser_event]),
         {
           'CONTENT_TYPE' => 'application/json',
           'HTTP_HOST' => 'app.example.com',
           'HTTP_ORIGIN' => 'https://app.example.com'
         }

    expect(last_response.status).to eq(202)
    expect(last_response.headers.fetch('Content-Type')).to include('application/json')
    expect(JSON.parse(last_response.body)).to include('accepted' => 1, 'rejected' => 0)
    expect(@transport_events.fetch(0).fetch(:events).fetch(0).fetch('service')).to include(
      'name' => 'rails-checkout',
      'environment' => 'production'
    )

    post '/debugbundle/browser',
         JSON.generate('batch' => [browser_event]),
         {
           'CONTENT_TYPE' => 'application/json',
           'HTTP_HOST' => 'app.example.com',
           'HTTP_ORIGIN' => 'https://app.example.com'
         }

    expect(last_response.status).to eq(404)
  end

  def build_rails_app
    @transport_events = []
    forward_transport = Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(@transport_events)

    app_class = Class.new(Rails::Application) do
      config.root = File.expand_path('..', __dir__)
      config.eager_load = false
      config.secret_key_base = 'test-secret'
      config.logger = Logger.new(nil)
    end

    app_class.config.hosts << 'app.example.com' if app_class.config.respond_to?(:hosts)
    app_class.config.debugbundle.project_token = 'dbundle_proj_test'
    app_class.config.debugbundle.service = 'rails-checkout'
    app_class.config.debugbundle.environment = 'production'
    app_class.config.debugbundle.relay_durable_write = false
    app_class.config.debugbundle.relay_allowed_origins = ['https://app.example.com']
    app_class.config.debugbundle.relay_forward_transport = forward_transport
    app_class.config.debugbundle.relay_path = '/relay/browser'
    app_class.initialize!
    app_class
  end

  def browser_event
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
  end
end
