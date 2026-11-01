# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'tmpdir'

RSpec.describe 'Byte-bounded client delivery' do
  it 'preserves an admissible local file event above the unrelated HTTP body limit' do
    Dir.mktmpdir do |directory|
      client = DebugBundle::Client.new(project_mode: :local_only, project_token: 't' * 8192,
                                       local_events_dir: directory, flush_interval: 3600, batch_size: 1000)
      expect(client).to receive(:fit_protected_event).with(kind_of(Hash)).and_call_original
      context = 13.times.to_h { |index| ["detail_#{index}", Array.new(10) { 'x' * 1000 }] }
      client.capture_log('local primary', level: :error, context: context)
      expect(client.buffered_event_count).to eq(1)
      expect(client.flush).to be(true)
      stored = JSON.parse(File.read(Dir.glob(File.join(directory, '*.events.json')).first))
      expect(stored.first.dig('payload', 'message')).to eq('local primary')
      expect(JSON.generate(stored.first).bytesize).to be > 262_144
    ensure
      client&.close
    end
  end

  it 'sends every primary in bounded requests with chunk-local acknowledgement indices' do
    requests = Queue.new
    transport = lambda do |request|
      events = request.fetch(:events)
      requests << events
      rejected = events.first.dig('payload', 'message') == 'failure 0' ? 1 : 0
      errors = rejected.zero? ? [] : [{ 'index' => 1, 'reason' => 'invalid_event' }]
      DebugBundle::Transport::Result.new(status_code: 202, body: {
                                           'accepted' => events.length - rejected, 'rejected' => rejected,
                                           'errors' => errors
                                         })
    end
    client = DebugBundle::Client.new(project_token: 'synthetic', transport: transport,
                                     flush_interval: 3600, batch_size: 1000,
                                     before_send: lambda { |event|
                                       event['context'] = 20.times.to_h { |index| ["detail_#{index}", 'x' * 4096] }
                                       event
                                     })
    5.times { |index| client.capture_log("failure #{index}", level: :error) }
    client.flush
    Timeout.timeout(5) { sleep(0.005) until client.buffered_event_count.zero? }
    sent = []
    sent << requests.pop until requests.empty?
    expect(sent.length).to be > 1
    expect(sent.map { |events| JSON.generate(events: events).bytesize }.max).to be <= 262_144
    expect(sent.flatten.map { |event| event.dig('payload', 'message') }).to eq(5.times.map { |i| "failure #{i}" })
  ensure
    client&.close
  end

  it 'withholds an oversized valid hook replacement without restoring pre-hook content' do
    delivered = []
    client = DebugBundle::Client.new(project_token: 'synthetic', batch_size: 1000, flush_interval: 3600,
                                     transport: lambda { |request|
                                       delivered.concat(request.fetch(:events))
                                       DebugBundle::Transport::Result.new(status_code: 202)
                                     }, before_send: lambda { |event|
                                       event['payload']['message'] = 'safe replacement'
                                       event['context'] = 63.times.to_h { |index| ["detail_#{index}", 'x' * 4000] }
                                       event['sdk_version'] = '\\' * 8000
                                       event
                                     })
    client.capture_log('original primary', level: :error)
    expect(client.flush).to be(true)
    expect(delivered).to be_empty
    expect(client.buffered_event_count).to eq(0)
  ensure
    client&.close
  end

  it 'withholds a schema-valid hook result when bounded validation cannot copy all its bytes' do
    delivered = []
    client = DebugBundle::Client.new(project_token: 'synthetic', batch_size: 1000, flush_interval: 3600,
                                     transport: lambda { |request|
                                       delivered.concat(request.fetch(:events))
                                       DebugBundle::Transport::Result.new(status_code: 202)
                                     }, before_send: lambda { |event|
                                       event['payload']['message'] = 'safe replacement'
                                       event['context'] = { 'oversized' => 'x' * ((8 * 1024 * 1024) + 1) }
                                       event
                                     })
    client.capture_log('private original before hook', level: :error)
    client.flush
    expect(delivered).to be_empty
    expect(client.buffered_event_count).to eq(0)
  ensure
    client&.close
  end

  it 'keeps a larger local hook replacement within existing ownership and privacy budgets' do
    Dir.mktmpdir do |directory|
      client = DebugBundle::Client.new(project_mode: :local_only, project_token: 'synthetic',
                                       local_events_dir: directory, flush_interval: 3600, batch_size: 1000,
                                       before_send: lambda { |event|
                                         event['payload']['message'] = 'safe local replacement'
                                         event['context'] = 14.times.to_h { |i| ["detail_#{i}", 'x' * 16_000] }
                                         %w[schema_version sdk_name sdk_version].each do |key|
                                           event[key] = 'v' * 16_000
                                         end
                                         event
                                       })
      client.capture_log('private original before hook', level: :error)
      expect(client.flush).to be(true)
      content = File.read(Dir.glob(File.join(directory, '*.events.json')).first)
      expect(content.bytesize).to be > 262_144
      expect(content).not_to include('private original before hook')
      expect(JSON.parse(content).first.dig('payload', 'message')).to eq('safe local replacement')
    ensure
      client&.close
    end
  end
end
