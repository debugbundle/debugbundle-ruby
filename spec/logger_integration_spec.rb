# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'stdlib logger integration' do
  it 'captures log events without changing logger output' do
    transport_events = []
    transport = Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(transport_events)

    output = StringIO.new
    logger = Logger.new(output)
    logger.progname = 'checkout'

    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport)
    client.capture_logger(logger)
    client.capture_logger(logger)

    logger.warn('payment retry failed')
    client.flush

    event = transport_events.fetch(0).fetch(:events).fetch(0)

    expect(output.string).to include('payment retry failed')
    expect(event.fetch('event_type')).to eq('log_event')
    expect(event.fetch('payload')).to include('message' => 'payment retry failed', 'level' => 'warning')
    expect(event.fetch('payload').fetch('attributes')).to include('logger_name' => 'checkout')
  end

  it 'registers a semantic logger appender when SemanticLogger is available' do
    transport_events = []
    transport = Class.new do
      define_method(:initialize) do |transport_events|
        @transport_events = transport_events
      end

      define_method(:call) do |request|
        @transport_events << request
        DebugBundle::Transport::Result.new(status_code: 202)
      end
    end.new(transport_events)

    semantic_logger = Module.new do
      class << self
        attr_reader :appenders

        def add_appender(appender:)
          @appenders ||= []
          @appenders << appender
        end
      end
    end

    stub_const('SemanticLogger', semantic_logger)

    log_entry = Struct.new(:message, :level, :name, :payload, :tags).new(
      'semantic failure',
      :error,
      'semantic-checkout',
      { order_id: 123 },
      %w[payments critical]
    )

    client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport)
    appender = client.capture_semantic_logger
    appender.log(log_entry)
    client.flush

    event = transport_events.fetch(0).fetch(:events).fetch(0)

    expect(SemanticLogger.appenders).to include(appender)
    expect(event.fetch('payload')).to include('message' => 'semantic failure', 'level' => 'error')
    expect(event.fetch('payload').fetch('attributes')).to include(
      'logger_name' => 'semantic-checkout',
      'payload' => { 'order_id' => 123 },
      'tags' => %w[payments critical]
    )
  end

  it 'guards semantic logger capture against recursive SDK logging' do
    capture_count = 0
    appender = nil
    log_entry = Struct.new(:message, :level, :name, :payload, :tags).new(
      'semantic recursion check',
      :error,
      'semantic-checkout',
      {},
      []
    )
    recursive_client = Class.new do
      define_method(:initialize) do |on_capture|
        @on_capture = on_capture
      end

      define_method(:capture_log) do |_message, level:, context:|
        @on_capture.call(level, context)
      end
    end.new(lambda do |_level, _context|
      capture_count += 1
      appender.log(log_entry)
    end)

    appender = DebugBundle::Logging::SemanticLoggerAppender.new(client: recursive_client)

    appender.log(log_entry)

    expect(capture_count).to eq(1)
  end
end
