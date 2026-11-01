# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe DebugBundle::Transport::HttpTransport do
  let(:http) { instance_double(Net::HTTP) }
  let(:response) { Net::HTTPAccepted.new('1.1', '202', 'Accepted') }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
  end

  it 'negotiates evidence on the existing POST and reads bounded response chunks' do
    allow(http).to receive(:post) do |path, body, headers, &consume|
      expect(path).to eq('/v1/events')
      expect(JSON.parse(body)).to eq('events' => [])
      expect(headers).to include('X-DebugBundle-Evidence' => '1', 'Accept-Encoding' => 'identity')
      consume.call('{"accepted":')
      consume.call('0,"rejected":0,"errors":[]}')
      response
    end
    result = described_class.new('https://example.invalid/v1/events').call(project_token: 'synthetic', events: [])
    expect(result.status_code).to eq(202)
    expect(result.body).to eq('accepted' => 0, 'rejected' => 0, 'errors' => [])
  end

  it 'rejects oversize bodies before retaining more than the response budget' do
    consumed = 0
    allow(http).to receive(:post) do |_path, _body, _headers, &consume|
      20.times do
        consumed += 1
        consume.call('x' * 32_768)
      end
      response
    end
    result = described_class.new('https://example.invalid/v1/events').call(project_token: 'synthetic', events: [])
    expect(result.status_code).to eq(500)
    expect(consumed).to eq(9)
  end

  it 'streams a real local chunked reply with identity encoding and evidence negotiation' do
    allow(Net::HTTP).to receive(:new).and_call_original
    server = TCPServer.new('127.0.0.1', 0)
    headers = []
    worker = Thread.new do
      socket = server.accept
      while (line = socket.gets) && line != "\r\n"
        headers << line
      end
      socket.write("HTTP/1.1 202 Accepted\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
      ['{"accepted":0,', '"rejected":0,"errors":[]}'].each do |chunk|
        socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
      end
      socket.write("0\r\n\r\n")
    ensure
      socket&.close
    end
    result = described_class.new("http://127.0.0.1:#{server.addr[1]}/v1/events").call(
      project_token: 'synthetic', events: []
    )
    expect(result.body).to eq('accepted' => 0, 'rejected' => 0, 'errors' => [])
    expect(headers.join.downcase).to include("accept-encoding: identity\r\n", "x-debugbundle-evidence: 1\r\n")
  ensure
    server&.close
    worker&.join(2)
    worker&.kill if worker&.alive?
  end
end
