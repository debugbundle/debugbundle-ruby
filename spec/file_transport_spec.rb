# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

RSpec.describe DebugBundle::Transport::FileTransport do
  it 'derives the remote SDK config endpoint from the events endpoint' do
    expect(DebugBundle::Transport.sdk_config_endpoint('https://api.debugbundle.com/v1/events')).to eq(
      'https://api.debugbundle.com/v1/sdk/config'
    )
    expect(DebugBundle::Transport.sdk_config_endpoint('https://api.debugbundle.com/events')).to eq(
      'https://api.debugbundle.com/sdk/config'
    )
    expect(DebugBundle::Transport.sdk_config_endpoint('https://api.debugbundle.com/v1/sdk/config')).to eq(
      'https://api.debugbundle.com/v1/sdk/config'
    )
  end

  it 'writes local event batches with secure permissions' do
    Dir.mktmpdir do |directory|
      transport = described_class.new(directory)
      result = transport.call(
        project_token: 'dbundle_proj_test',
        service_name: 'checkout-api',
        events: [{ 'event_type' => 'log_event', 'payload' => { 'message' => 'ok' } }]
      )

      expect(result.status_code).to eq(202)

      file_path = Dir.children(directory).find { |name| name.end_with?('.events.json') }
      expect(file_path).not_to be_nil

      full_path = File.join(directory, file_path)
      parsed = JSON.parse(File.read(full_path))
      expect(parsed.length).to eq(1)
      expect(parsed.fetch(0)).to include('event_type' => 'log_event')
      expect(File.stat(full_path).mode & 0o777).to eq(0o600)
      expect(File.stat(directory).mode & 0o777).to eq(0o700)
    end
  end

  it 'rejects traversal-style local event directories without raising into the caller' do
    transport = described_class.new('../debugbundle-events')

    result = transport.call(
      project_token: 'dbundle_proj_test',
      service_name: 'checkout-api',
      events: [{ 'event_type' => 'log_event', 'payload' => { 'message' => 'ok' } }]
    )

    expect(result.status_code).to eq(500)
  end

  it 'creates a secure delivery marker only for its own regular spool file' do
    Dir.mktmpdir do |directory|
      transport = described_class.new(directory)
      written = transport.call(events: [{ 'event_type' => 'log_event' }])
      path = written.written_file_path
      expect(transport.mark_delivered(path)).to be(true)
      expect(File.stat("#{path}.delivered").mode & 0o777).to eq(0o600)
      expect(transport.mark_delivered(path)).to be(false)
      link = File.join(directory, 'linked.events.json')
      File.symlink(path, link)
      expect(transport.mark_delivered(link)).to be(false)
      expect(transport.mark_delivered(File.join(directory, 'missing.events.json'))).to be(false)
      expect(transport.mark_delivered(File.join(File.dirname(directory), 'foreign.events.json'))).to be(false)
      expect(File.read(path)).not_to be_empty
    end
  end
end
