# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'HTTP acknowledgement reliability' do
  [429, 503, :protocol, :partial].each do |outcome|
    it "honors capped retry hints and recovers after #{outcome}" do
      now = Time.now.utc
      calls = 0
      transport = lambda do |_request|
        calls += 1
        body = case outcome
               when :protocol then { 'accepted' => 2, 'rejected' => 0, 'errors' => [] }
               when :partial then { 'accepted' => 0, 'rejected' => 1,
                                    'errors' => [{ 'index' => 0, 'reason' => 'rate_limited' }] }
               end
        DebugBundle::Transport::Result.new(status_code: if calls > 1
                                                          202
                                                        else
                                                          outcome.is_a?(Integer) ? outcome : 202
                                                        end,
                                           retry_after_seconds: 1e100, body: calls == 1 ? body : nil)
      end
      client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport,
                                       flush_interval: 3600, time_provider: -> { now })
      begin
        client.capture_log('retained', level: :error)
        client.flush
        now += 299
        client.flush
        expect(calls).to eq(1)
        expect(client.last_event_at).to be_nil
        expect(client.buffered_event_count).to eq(1)
        now += 2
        expect(client.flush).to be(true)
        expect(calls).to eq(2)
        expect(client.buffered_event_count).to eq(0)
      ensure
        client.close
      end
    end
  end

  it 'bounds finite HTTP headers before conversion and ignores nonfinite headers' do
    response = Net::HTTPTooManyRequests.new('1.1', '429', 'Too Many Requests')
    allow(response).to receive(:body).and_return('{}')
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:post).and_return(response)
    transport = DebugBundle::Transport::HttpTransport.new('https://example.invalid/events')
    { '1e300' => 300, 'NaN' => nil, 'Infinity' => nil, '-Infinity' => nil, '-1' => 0,
      '0.25' => 0, (Time.now.utc + 86_400).httpdate => 300,
      (Time.now.utc + 86_400).strftime('%A, %d-%b-%y %H:%M:%S GMT') => 300,
      (Time.now.utc + 86_400).asctime => 300 }.each do |header, expected|
      allow(response).to receive(:[]).with('Retry-After').and_return(header)
      result = transport.call(project_token: 'dbundle_proj_test', events: [])
      expect(result.status_code).to eq(429)
      expect(result.retry_after_seconds).to eq(expected)
    end
  end

  [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |hint|
    it "uses bounded fallback backoff for a nonfinite custom retry hint #{hint}" do
      now = Time.now.utc
      calls = 0
      transport = lambda do |_request|
        calls += 1
        DebugBundle::Transport::Result.new(status_code: calls == 1 ? 429 : 202, retry_after_seconds: hint)
      end
      client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport,
                                       flush_interval: 3600, time_provider: -> { now })
      begin
        client.capture_log('retained', level: :error)
        client.flush
        expect(client.last_event_at).to be_nil
        client.flush
        expect(calls).to eq(1)
        now += 2
        expect(client.flush).to be(true)
        expect(calls).to eq(2)
        expect(client.buffered_event_count).to eq(0)
      ensure
        client.close
      end
    end
  end

  ['',
   '{"accepted":null,"rejected":2,"errors":[{"index":0,"reason":"rate_limited"},{"index":1,"reason":"rate_limited"}]}',
   '{"accepted":2,"rejected":0,"errors":null}',
   '{"accepted":1,"rejected":1,"errors":[{"index":4294967296,"reason":"rate_limited"}]}',
   '{"accepted":1,"rejected":1,"errors":{"one":{"index":1,"reason":"rate_limited"}}}',
   '<html>proxy</html>', '{}', '[]', 'null',
   '{"accepted":1,"rejected":0,"errors":[]}',
   '{"accepted":0,"rejected":2,"errors":[{"index":0,"reason":"rate_limited"},{"index":0,"reason":"rate_limited"}]}',
   '{"accepted":1,"rejected":1,"errors":[{"index":2,"reason":"rate_limited"}]}'].each do |body|
    it "retains and recovers the full batch for invalid HTTP body #{body.inspect}" do
      now = Time.now.utc
      response = Net::HTTPAccepted.new('1.1', '202', 'Accepted')
      allow(response).to receive(:body).and_return(body, '{"accepted":2,"rejected":0,"errors":[]}')
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:post).and_return(response)
      transport = DebugBundle::Transport::HttpTransport.new('https://example.invalid/events')
      client = DebugBundle::Client.new(project_token: 'dbundle_proj_test', transport: transport,
                                       flush_interval: 3600, time_provider: -> { now })
      begin
        client.capture_log('first', level: :error)
        client.capture_log('second', level: :error)
        expect(client.flush).to be(false)
        expect(client.last_event_at).to be_nil
        expect(client.buffered_event_count).to eq(2)
        client.flush
        expect(http).to have_received(:post).once
        now += 2
        expect(client.flush).to be(true)
        expect(client.buffered_event_count).to eq(0)
        expect(client.last_event_at).not_to be_nil
        expect(http).to have_received(:post).twice
      ensure
        client.close
      end
    end
  end
end
