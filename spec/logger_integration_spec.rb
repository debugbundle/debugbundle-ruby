# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'stdlib logger integration' do
  def instrument_logger(logger, &capture)
    client = Object.new
    client.define_singleton_method(:capture_log, &capture)
    DebugBundle::Logging.install_stdlib_logger(logger, client: client)
  end

  it 'respects the current logger level without evaluating suppressed blocks' do
    output = StringIO.new
    logger = Logger.new(output, level: Logger::ERROR)
    captured = []
    instrument_logger(logger) { |message, **_options| captured << message }
    evaluations = 0
    result = logger.warn do
      evaluations += 1
      'suppressed'
    end
    expect(result).to be(true)
    expect(captured).to be_empty
    expect(evaluations).to eq(0)
    logger.level = Logger::WARN
    logger.warn do
      evaluations += 1
      'accepted'
    end
    expect(evaluations).to eq(1)
    expect(captured).to eq(['accepted'])
    expect(output.string).to include('accepted')
    expect(output.string).not_to include('suppressed')
  end

  it 'preserves logger message and progname semantics and evaluates accepted blocks once' do
    output = StringIO.new
    logger = Logger.new(output, progname: 'default-name')
    captured = []
    instrument_logger(logger) { |message, **_options| captured << message }
    logger.add(Logger::WARN)
    logger.add(Logger::WARN, nil, 'message-as-progname')
    logger.add(nil, 'unknown-severity')
    evaluations = 0
    logger.warn('explicit-name') do
      evaluations += 1
      "block-#{evaluations}"
    end
    expect(captured).to eq(%w[default-name message-as-progname unknown-severity block-1])
    expect(evaluations).to eq(1)
    expect(output.string).to include('explicit-name: block-1')
  end

  it 'does not evaluate blocks or capture when the logger has no output device' do
    logger = Logger.new(nil)
    instrument_logger(logger) { raise 'should not capture' }
    expect(logger.warn { raise 'should not evaluate' }).to be(true)
  end

  it 'captures the log alias and preserves false messages and Rails silence' do
    require 'active_support'
    require 'active_support/logger'
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    captured = []
    instrument_logger(logger) { |message, **_options| captured << message }
    logger.silence(Logger::ERROR) { logger.warn { raise 'suppressed block' } }
    logger.log(Logger::WARN, false)
    expect(captured).to eq(['false'])
    expect(output.string).to include('false')
  end

  it 'isolates capture failures and recursion while preserving application logging failures' do
    output = StringIO.new
    logger = Logger.new(output)
    calls = 0
    instrument_logger(logger) do |_message, **_options|
      calls += 1
      logger.warn('nested')
      raise 'capture failed'
    end
    expect { logger.warn('outer') }.not_to raise_error
    expect(calls).to eq(1)
    expect(output.string).to include('outer', 'nested')
    expect { logger.warn { raise 'application failure' } }.to raise_error('application failure')
    expect { logger.warn('after failure') }.not_to raise_error
    expect(calls).to eq(2)
  end

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
