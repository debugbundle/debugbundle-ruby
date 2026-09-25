# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe DebugBundle::Client do
  it 'keeps sender-held records charged and evicts only unsent records' do
    entered = Queue.new
    release = Queue.new
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 2000, flush_interval: 3600,
                                 transport: lambda { |request|
                                   entered << request[:events]
                                   release.pop
                                   DebugBundle::Transport::Result.new(status_code: 500)
                                 })
    1000.times { |index| client.capture_log("ordinary #{index}", level: :warning) }
    flusher = Thread.new { client.flush }
    inflight = Timeout.timeout(5) { entered.pop }
    1000.times { |index| client.capture_exception(RuntimeError.new("failure #{index}")) }
    pending = client.__send__(:buffered_batch)

    expect((inflight + pending).map { |event| event['event_id'] }.uniq.length).to be <= 1000
    expect(pending.map { |event| event['event_id'] }).to eq(inflight.map { |event| event['event_id'] })
    release << true
    flusher.join
    client.capture_exception(RuntimeError.new('after sender release'))
    expect(client.__send__(:buffered_batch).any? { |event| event['event_type'] == 'backend_exception' }).to be(true)
  ensure
    release << true
    flusher&.join
    client&.close
  end

  it 'charges valid hook replacements before retaining or sending them and caches retries' do
    entered = Queue.new
    release = Queue.new
    hooks = Hash.new(0)
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 2000, flush_interval: 3600,
                                 before_send: lambda { |event|
                                   hooks[event['event_id']] += 1
                                   event['context'] = 20.times.to_h { |index| ["detail_#{index}", 'x' * 4096] }
                                   event
                                 },
                                 transport: lambda { |request|
                                   entered << request[:events]
                                   DebugBundle::Transport::Result.new(status_code: release.pop)
                                 })
    150.times { |index| client.capture_log("failure #{index}", level: :error) }
    flusher = Thread.new { client.flush }
    inflight = Timeout.timeout(5) { entered.pop }
    expect(inflight).not_to be_empty
    expect(inflight.length).to be < 150
    expect(JSON.generate(inflight).bytesize).to be <= described_class::MAX_BUFFER_BYTES
    expect(client.instance_variable_get(:@buffer_bytes)).to be <= described_class::MAX_BUFFER_BYTES
    expect(client.instance_variable_get(:@buffer_bytes)).to be >= inflight.sum { |event| JSON.generate(event).bytesize }
    release << 500
    flusher.join
    hook_count = hooks.dup

    flusher = Thread.new { client.flush }
    retry_batch = Timeout.timeout(5) { entered.pop }
    expect(retry_batch).to eq(inflight)
    inflight.each { |event| expect(hooks[event['event_id']]).to eq(hook_count[event['event_id']]) }
    release << 202
    flusher.join
  ensure
    release << 202
    flusher&.join
    client&.close
  end

  it 'captures built-in exception details without invoking application overrides' do
    hostile_error = Class.new(StandardError) do
      def message = raise('application message override must not run')
      def to_s = raise('application string override must not run')
      def backtrace = raise('application backtrace override must not run')
      def cause = raise('application cause override must not run')
    end.new('stored failure')
    hostile_error.set_backtrace(['app/checkout.rb:17:in `pay`'])
    delivered = Queue.new
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 1,
                                 transport: lambda { |request|
                                   delivered << request[:events]
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 })
    expect { client.capture_exception(hostile_error) }.not_to raise_error
    events = Timeout.timeout(2) { delivered.pop }
    exception = events.find { |event| event['event_type'] == 'backend_exception' }
    expect(exception.dig('payload', 'message')).to eq('stored failure')
    expect(exception.dig('payload', 'stack')).to include('app/checkout.rb:17')
  ensure
    client&.close
  end

  it 'caps retained exception stack frames before building the event' do
    error = RuntimeError.new('bounded stack')
    error.set_backtrace(Array.new(300) { |index| "app/worker_#{index}.rb:#{index}:#{'x' * 900}" })
    delivered = Queue.new
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 1,
                                 transport: lambda { |request|
                                   delivered << request[:events]
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 })

    client.capture_exception(error)
    exception = Timeout.timeout(2) { delivered.pop }.find { |event| event['event_type'] == 'backend_exception' }
    stack = exception.dig('payload', 'stack')
    expect(stack.bytesize).to be <= 16_384
    expect(stack.lines.length).to be <= 64
    expect(stack).to include('app/worker_0.rb')
    expect(stack).not_to include('app/worker_299.rb')
  ensure
    client&.close
  end

  it 'does not invoke application type-name overrides while capturing an exception' do
    error_type = Class.new(StandardError)
    error_type.define_singleton_method(:name) { raise 'application type-name override must not run' }
    error = error_type.new('original failure')
    error.define_singleton_method(:class) { raise 'application class override must not run' }
    delivered = Queue.new
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 1,
                                 transport: lambda { |request|
                                   delivered << request[:events]
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 })

    expect { client.capture_exception(error) }.not_to raise_error
    exception = Timeout.timeout(2) { delivered.pop }.find { |event| event['event_type'] == 'backend_exception' }
    expect(exception.dig('payload', 'message')).to eq('original failure')
    expect(exception.dig('payload', 'name')).to be_a(String)
  ensure
    client&.close
  end

  it 'does not render an application object on the accepted log capture path' do
    message = Object.new
    message.define_singleton_method(:to_s) { raise 'application log renderer must not run' }
    delivered = Queue.new
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 1,
                                 transport: lambda { |request|
                                   delivered << request[:events]
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 })

    expect { client.capture_log(message, level: :error) }.not_to raise_error
    event = Timeout.timeout(2) { delivered.pop }.find { |candidate| candidate['event_type'] == 'log_event' }
    expect(event.dig('payload', 'message')).to eq('[unsupported log message]')
    client.capture_log(42, level: :error)
    numeric = Timeout.timeout(2) { delivered.pop }.find { |candidate| candidate['event_type'] == 'log_event' }
    expect(numeric.dig('payload', 'message')).to eq('42')
  ensure
    client&.close
  end

  it 'does not invoke application conversion methods for accepted context values or keys' do
    hostile = Object.new
    hostile.define_singleton_method(:to_s) { raise 'application conversion must not run' }
    hostile.define_singleton_method(:to_h) { raise 'application conversion must not run' }
    delivered = Queue.new
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 1,
                                 transport: lambda { |request|
                                   delivered << request[:events]
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 })
    client.set_context(42, 'numeric key')
    client.set_context(2**513, 'discard large key')

    expect do
      client.capture_log('context failure', level: :error, context: { 'safe' => hostile, hostile => 'discard key' })
    end.not_to raise_error
    event = Timeout.timeout(2) { delivered.pop }.find { |candidate| candidate['event_type'] == 'log_event' }
    expect(event.fetch('context')).to include('safe' => '[unsupported value]')
    expect(event.fetch('context')).to include('42' => 'numeric key')
    expect(event.fetch('context')).not_to have_key('discard key')
  ensure
    client&.close
  end

  it 'does not render an application object while matching a client-error request path' do
    hostile = Object.new
    hostile.define_singleton_method(:to_s) { raise 'application path renderer must not run' }
    fetcher = lambda do |_etag|
      { status_code: 200, body: { capture_policy: {
        capture_request_events: 'failures_only',
        immediate_client_error_path_rules: [
          { status_code: 422, path_pattern: '/checkout/*', methods: ['POST'] }
        ]
      } } }
    end
    client = described_class.new(project_token: 'dbundle_proj_test',
                                 transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) },
                                 config_fetcher: fetcher)
    expect(client.refresh_remote_config!).to be(true)

    expect { client.capture_request({ method: 'POST', path: hostile }, { status_code: 422 }) }.not_to raise_error
    expect(client.buffered_event_count).to eq(0)
    client.capture_request({ method: 'POST', path: '/checkout/%zz?x=1' }, { status_code: 422 })
    expect(client.buffered_event_count).to eq(1)
  ensure
    client&.close
  end

  it 'does not convert an application request object on the capture caller' do
    conversions = 0
    request = Object.new
    request.define_singleton_method(:to_h) do
      conversions += 1
      { method: 'GET', path: '/converted' }
    end
    client = described_class.new(project_token: 'dbundle_proj_test', batch_size: 25,
                                 transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) })

    client.capture_request(request, { status_code: 503 })

    expect(conversions).to eq(0)
    event = client.__send__(:buffered_batch).find { |candidate| candidate['event_type'] == 'request_event' }
    expect(event.dig('payload', 'path')).to eq('/')
  ensure
    client&.close
  end

  it 'rejects ten thousand INFO records before hooks or delivery' do
    hooks = 0
    sends = 0
    transport = lambda do |_request|
      sends += 1
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 log_level: :warning, before_send: lambda { |event|
                                   hooks += 1
                                   event
                                 })

    10_000.times { client.capture_log('filtered INFO', level: :info, context: { index: 1 }) }

    expect(hooks).to eq(0)
    expect(sends).to eq(0)
    expect(client.buffered_event_count).to eq(0)
  end

  it 'delivers a full batch automatically without making capture wait for transport' do
    entered = Queue.new
    release = Queue.new
    transport = lambda do |_request|
      entered << true
      release.pop
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport, batch_size: 1)
    client.capture_log('first error', level: :error)
    Timeout.timeout(2) { entered.pop }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.capture_log('second error', level: :error)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.25
  ensure
    release << true if defined?(release) && release
  end

  it 'returns from construction while remote configuration is stalled' do
    entered = Queue.new
    release = Queue.new
    fetcher = lambda do |_etag|
      entered << true
      release.pop
      { status_code: 500, body: {} }
    end
    built = Queue.new
    builder = Thread.new do
      built << described_class.new(project_token: 'dbundle_proj_test', transport: ->(_request) {},
                                   config_fetcher: fetcher)
    end
    Timeout.timeout(2) { entered.pop }
    expect(Timeout.timeout(0.25) { built.pop }).to be_a(described_class)
  ensure
    release << true if defined?(release) && release
    builder&.join(1)
  end

  it 'delivers an ERROR while remote configuration retrieval is stalled' do
    config_entered = Queue.new
    release_config = Queue.new
    delivered = Queue.new
    fetcher = lambda do |_etag|
      config_entered << true
      release_config.pop
      { status_code: 500, body: {} }
    end
    transport = lambda do |request|
      delivered << request.fetch(:events)
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 config_fetcher: fetcher, batch_size: 1)
    Timeout.timeout(2) { config_entered.pop }

    client.capture_log('accepted error', level: :error)

    events = Timeout.timeout(0.5) { delivered.pop }
    expect(events.map { |event| event.dig('payload', 'message') }).to include('accepted error')
  ensure
    release_config << true if defined?(release_config) && release_config
    client&.close
  end

  it 'runs a stalled before_send hook away from the capture caller' do
    entered = Queue.new
    release = Queue.new
    hook = lambda do |event|
      entered << true
      release.pop
      event
    end
    transport = ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) }
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 batch_size: 1, before_send: hook)
    caller = Thread.new { client.capture_log('failure', level: :error) }
    Timeout.timeout(2) { entered.pop }
    expect(caller.join(0.25)).not_to be_nil
  ensure
    release << true if defined?(release) && release
    caller&.join(1)
    client&.close
  end

  it 'rejects every log level when remote capture policy is off' do
    transport = ->(_request) { raise 'filtered logs must not send' }
    fetcher = lambda do |_etag|
      { status_code: 200, body: { capture_policy: { capture_logs: 'off' } } }
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 config_fetcher: fetcher)
    expect(client.refresh_remote_config!).to be(true)

    client.capture_log('fatal is disabled too', level: :fatal)

    expect(client.buffered_event_count).to eq(0)
  ensure
    client&.close
  end

  it 'retains an exception ahead of lower-priority logs when the sender is held' do
    entered = Queue.new
    release = Queue.new
    transport = lambda do |_request|
      entered << true
      release.pop
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 batch_size: 1)
    client.capture_exception(RuntimeError.new('retain this failure'))
    Timeout.timeout(2) { entered.pop }
    1_000.times { |index| client.capture_log("warning #{index}", level: :warning) }

    expect(client.buffered_event_count).to be <= 1_000
    expect(client.__send__(:buffered_batch).any? { |event| event['event_type'] == 'backend_exception' }).to be(true)
  ensure
    release << true if defined?(release) && release
    client&.close
  end

  it 'retains a failed request ahead of ordinary request traffic under pressure' do
    stub_const('DebugBundle::Client::MAX_BUFFER_SIZE', 2)
    fetcher = lambda do |_etag|
      { status_code: 200, body: { capture_policy: { capture_request_events: 'all' } } }
    end
    client = described_class.new(project_token: 'dbundle_proj_test',
                                 transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) },
                                 config_fetcher: fetcher, batch_size: 25)
    expect(client.refresh_remote_config!).to be(true)
    2.times do |index|
      client.capture_request({ method: 'GET', path: "/ordinary/#{index}" }, { status_code: 200 })
    end
    client.capture_request({ method: 'GET', path: '/failed' }, { status_code: 503 })

    expect(client.buffered_event_count).to eq(2)
    expect(client.__send__(:buffered_batch).any? do |event|
      event['event_type'] == 'request_event' && event.dig('payload', 'response_status') == 503
    end).to be(true)
  ensure
    client&.close
  end

  it 'rejects an all-ERROR burst before rendering messages when the queue is full' do
    stub_const('DebugBundle::Client::MAX_BUFFER_SIZE', 2)
    deliveries = []
    client = described_class.new(project_token: 'dbundle_proj_test',
                                 transport: lambda { |request|
                                   deliveries.concat(request.fetch(:events))
                                   DebugBundle::Transport::Result.new(status_code: 202)
                                 },
                                 batch_size: 25)
    client.capture_log('first error', level: :error)
    client.capture_log('second error', level: :error)
    rendered = 0
    message = Object.new
    message.define_singleton_method(:to_s) do
      rendered += 1
      'dropped error'
    end

    10_000.times { client.capture_log(message, level: :error) }

    expect(rendered).to eq(0)
    expect(client.buffered_event_count).to eq(2)
    expect(client.instance_variable_get(:@pressure_drops).fetch('error').fetch(:count)).to eq(10_000)
    expect(client.flush).to be(true)
    expect(client.flush).to be(true)
    reports = deliveries.select { |event| event['event_type'] == 'error_suppressed' }
    expect(reports.length).to eq(1)
    expect(reports.first.fetch('payload')).to include('suppressed_count' => 10_000, 'level' => 'error')
  ensure
    client&.close
  end

  it 'rejects an all-exception burst before reading application exception properties' do
    stub_const('DebugBundle::Client::MAX_BUFFER_SIZE', 2)
    client = described_class.new(project_token: 'dbundle_proj_test',
                                 transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) },
                                 batch_size: 25)
    client.capture_exception(RuntimeError.new('first'))
    client.capture_exception(RuntimeError.new('second'))
    inspected = 0
    error_type = Class.new(StandardError) do
      define_method(:message) do
        inspected += 1
        'dropped exception'
      end
    end

    10_000.times { client.capture_exception(error_type.new) }

    expect(inspected).to eq(0)
    expect(client.buffered_event_count).to eq(2)
    expect(client.instance_variable_get(:@pressure_drops).fetch('exception').fetch(:count)).to eq(10_000)
  ensure
    client&.close
  end

  it 'reports queue-pressure drops once after room returns' do
    stub_const('DebugBundle::Client::MAX_BUFFER_SIZE', 2)
    deliveries = []
    transport = lambda do |request|
      deliveries.concat(request.fetch(:events))
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 batch_size: 25)
    3.times { |index| client.capture_log("warning #{index}", level: :warning) }

    expect(client.flush).to be(true)
    expect(client.flush).to be(true)
    expect(client.flush).to be(true)

    reports = deliveries.select { |event| event['event_type'] == 'error_suppressed' }
    expect(reports.length).to eq(1)
    expect(reports.first.fetch('payload')).to include(
      'suppressed_count' => 1, 'reason' => 'queue_pressure', 'level' => 'warning'
    )
  ensure
    client&.close
  end

  it 'restarts delivery in a forked child without replaying the parent buffer' do
    transport = ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) }
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport,
                                 batch_size: 25)
    client.capture_log('parent-only warning', level: :warning)
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      client.capture_log('child warning', level: :warning)
      buffered_count = client.buffered_event_count
      writer.write("#{buffered_count}:#{client.flush ? 'delivered' : 'not_delivered'}")
      writer.close
      exit! 0
    end
    writer.close
    Timeout.timeout(2) { Process.wait(pid) }
    pid = nil
    expect(reader.read).to eq('1:delivered')
  ensure
    Process.kill('KILL', pid) if pid && Process.waitpid(pid, Process::WNOHANG).nil?
    reader&.close
    writer&.close
    client&.close
  end

  it 'resets inherited capture state before the first child event' do
    delivered = []
    transport = lambda do |request|
      delivered.concat(request.fetch(:events))
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)
    client.set_context('parent_context', 'parent only')
    client.capture_log('parent warning', level: :warning)
    client.close

    client.instance_variable_set(:@owner_pid, Process.pid - 1)
    client.capture_log('child warning', level: :warning)

    expect(client.buffered_event_count).to eq(1)
    expect(client.flush).to be(true)
    expect(delivered.map { |event| event.dig('payload', 'message') }).to eq(['child warning'])
    expect(JSON.generate(delivered.first)).not_to include('parent_context')
  ensure
    client&.close
  end

  it 'does not widen a restrictive parent capture policy during fork reset' do
    fetcher = lambda do |_etag|
      { status_code: 200, body: { capture_policy: { capture_logs: 'off' }, probes_enabled: false } }
    end
    client = described_class.new(project_token: 'dbundle_proj_test',
                                 transport: ->(_request) { DebugBundle::Transport::Result.new(status_code: 202) },
                                 config_fetcher: fetcher)
    expect(client.refresh_remote_config!).to be(true)
    client.close
    client.instance_variable_set(:@owner_pid, Process.pid - 1)

    client.capture_log('fatal remains disabled', level: :fatal)

    expect(client.buffered_event_count).to eq(0)
    expect(client.instance_variable_get(:@remote_config).probes_enabled).to be(false)
  ensure
    client&.close
  end

  it 'does not wait for a stalled sender in the automatic at-exit hook' do
    entered = Queue.new
    release = Queue.new
    transport = lambda do |_request|
      entered << true
      release.pop
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)
    registered_callback = nil
    allow(client).to receive(:at_exit) { |&block| registered_callback = block }
    client.capture_at_exit

    begin
      raise 'shutdown failure'
    rescue RuntimeError
      expect { Timeout.timeout(0.25) { registered_callback.call } }.not_to raise_error
    end
    Timeout.timeout(2) { entered.pop }
  ensure
    release << true if defined?(release) && release
    client&.close
  end

  it 'does not wait for a stalled sender in the automatic thread-exception hook' do
    entered = Queue.new
    release = Queue.new
    transport = lambda do |_request|
      entered << true
      release.pop
      DebugBundle::Transport::Result.new(status_code: 202)
    end
    client = described_class.new(project_token: 'dbundle_proj_test', transport: transport)

    expect do
      Timeout.timeout(0.25) { client.__send__(:capture_thread_exception, RuntimeError.new('thread failure')) }
    end.not_to raise_error
    Timeout.timeout(2) { entered.pop }
  ensure
    release << true if defined?(release) && release
    client&.close
  end
end
