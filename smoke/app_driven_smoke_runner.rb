# frozen_string_literal: true

require 'json'
require 'json_schemer'
require 'rack'
require 'rack/mock_request'
require 'socket'
require 'debugbundle'

PROJECT_TOKEN = 'dbundle_proj_smoke'
BACKEND_TRACE_ID = 'trace-smoke-backend'
BACKEND_REQUEST_ID = 'req-smoke-backend'
RELAY_TRACE_ID = 'trace-smoke-relay'
RELAY_REQUEST_ID = 'req-smoke-relay'
BROWSER_SERVICE = 'checkout-web'
BROWSER_ENVIRONMENT = 'production'

RecordedRequest = Struct.new(:http_method, :path, :headers, :body, keyword_init: true)

class MockIngestionServer
  def initialize
    @requests = []
    @mutex = Mutex.new
    @server = TCPServer.new('127.0.0.1', 0)
    @thread = Thread.new { serve }
  end

  def endpoint
    "http://127.0.0.1:#{@server.addr[1]}/v1/events"
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def close
    @server.close
    @thread.join(5)
  rescue IOError, Errno::EBADF
    nil
  end

  private

  def serve
    loop do
      socket = @server.accept
      handle(socket)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(socket)
    request_line = socket.gets("\r\n")
    return unless request_line

    method, path, = request_line.strip.split(' ', 3)
    headers = {}

    loop do
      line = socket.gets("\r\n")
      break if line.nil? || line == "\r\n"

      key, value = line.split(':', 2)
      headers[key.to_s.downcase] = value.to_s.strip
    end

    content_length = headers.fetch('content-length', '0').to_i
    raw_body = content_length.positive? ? socket.read(content_length) : ''
    parsed_body = raw_body.empty? ? {} : JSON.parse(raw_body)

    @mutex.synchronize do
      @requests << RecordedRequest.new(
        http_method: method,
        path: path,
        headers: headers,
        body: parsed_body
      )
    end

    status, body = response_for(method, path)
    payload = JSON.generate(body)
    socket.write("HTTP/1.1 #{status} #{reason_phrase(status)}\r\n")
    socket.write("Content-Type: application/json\r\n")
    socket.write("Content-Length: #{payload.bytesize}\r\n")
    socket.write("Connection: close\r\n")
    socket.write("\r\n")
    socket.write(payload)
  rescue JSON::ParserError
    socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
  ensure
    socket.close
  end

  def response_for(method, path)
    if method == 'GET' && path == '/v1/sdk/config'
      [200, {
        probes_enabled: true,
        remote_probes_enabled: false,
        active_probes: [],
        poll_interval_ms: 60_000,
        capture_policy: {
          preset: 'balanced',
          capture_logs: 'warning',
          capture_request_events: 'all',
          capture_breadcrumbs: 'exception_only',
          capture_probe_events: 'buffer_only'
        }
      }]
    elsif method == 'POST' && path == '/v1/events'
      [202, { accepted: 1, rejected: 0 }]
    else
      [404, { error: 'not_found' }]
    end
  end

  def reason_phrase(status)
    {
      200 => 'OK',
      202 => 'Accepted',
      400 => 'Bad Request',
      404 => 'Not Found'
    }.fetch(status, 'OK')
  end
end

def assert!(condition, message)
  raise message unless condition
end

def find_event(requests)
  requests.each do |request|
    events = request.body.fetch('events', nil)
    next unless events.is_a?(Array)

    events.each do |event|
      next unless event.is_a?(Hash)

      return [request, event] if yield(event)
    end
  end

  raise 'expected_smoke_event_was_not_delivered'
end

schema_path = ENV.fetch('DEBUGBUNDLE_SCHEMA_PATH')
expected_version = ENV.fetch('DEBUGBUNDLE_EXPECTED_VERSION')
schemer = JSONSchemer.schema(JSON.parse(File.read(schema_path)))

server = MockIngestionServer.new

DebugBundle.init(
  project_token: PROJECT_TOKEN,
  service: 'checkout-api',
  environment: 'production',
  endpoint: server.endpoint,
  log_level: :warning
)

backend_app = Rack::Builder.new do
  use DebugBundle::Rack::Middleware, client: DebugBundle.client

  run lambda { |env|
    correlation = {
      trace_id: env['HTTP_X_DEBUGBUNDLE_TRACE_ID'],
      request_id: env['HTTP_X_REQUEST_ID']
    }
    DebugBundle.capture_message(
      'ruby app-driven smoke message',
      level: :error,
      context: {
        feature: 'app-driven-smoke',
        correlation: correlation
      }
    )
    [503, { 'Content-Type' => 'application/json' }, [JSON.generate(ok: false, smoke: true)]]
  }
end.to_app

relay_handler = DebugBundle::Relay::Handler.new(
  project_mode: :connected,
  project_token: PROJECT_TOKEN,
  endpoint: server.endpoint,
  durable_write: false,
  allowed_origins: ['https://app.example.com']
)
relay_app = DebugBundle::Rack::RelayMiddleware.new(nil, handler: relay_handler)
app = Rack::URLMap.new('/debugbundle/browser' => relay_app, '/' => backend_app)
request = Rack::MockRequest.new(app)

begin
  backend_response = request.get(
    '/smoke',
    'HTTP_HOST' => 'api.example.com',
    'HTTP_X_DEBUGBUNDLE_TRACE_ID' => BACKEND_TRACE_ID,
    'HTTP_X_REQUEST_ID' => BACKEND_REQUEST_ID
  )
  assert!(backend_response.status == 503, "unexpected_backend_status: #{backend_response.status}")

  relay_response = request.post(
    '/debugbundle/browser',
    'HTTP_HOST' => 'api.example.com',
    'CONTENT_TYPE' => 'application/json',
    'HTTP_ORIGIN' => 'https://app.example.com',
    'HTTP_AUTHORIZATION' => 'Bearer browser-smuggled-token',
    'HTTP_COOKIE' => 'session=browser-smuggled-cookie',
    'REMOTE_ADDR' => '127.0.0.1',
    input: JSON.generate(
      batch: [
        {
          schema_version: '2026-03-01',
          event_id: '00000000-0000-4000-8000-000000000111',
          event_type: 'frontend_exception',
          occurred_at: '2026-05-26T12:00:00Z',
          sdk_name: 'spoofed-browser-sdk',
          sdk_version: '0.1.0',
          project_token: 'browser-smuggled-token',
          organization_id: 'org-smuggled',
          service: {
            name: BROWSER_SERVICE,
            runtime: 'browser',
            environment: BROWSER_ENVIRONMENT
          },
          correlation: {
            trace_id: RELAY_TRACE_ID,
            request_id: RELAY_REQUEST_ID,
            session_id: 'sess-smoke',
            user_id_hash: 'user-smoke'
          },
          payload: {
            message: 'ruby relay smoke message'
          }
        }
      ]
    )
  )
  assert!(relay_response.status == 202, "unexpected_relay_status: #{relay_response.status}")

  DebugBundle.flush
ensure
  server.close
end

assert!(DebugBundle.status == :healthy, "unexpected_client_status: #{DebugBundle.status}")
assert!(!DebugBundle.last_event_at.nil?, 'expected_last_event_at_to_be_recorded')

captured_requests = server.requests
config_request = captured_requests.find { |entry| entry.http_method == 'GET' && entry.path == '/v1/sdk/config' }
assert!(!config_request.nil?, 'expected_sdk_config_request')
assert!(
  config_request.headers['authorization'] == "Bearer #{PROJECT_TOKEN}",
  'expected_sdk_config_request_to_use_server_project_token'
)

ingestion_requests = captured_requests.select { |entry| entry.http_method == 'POST' && entry.path == '/v1/events' }
assert!(ingestion_requests.length >= 2, "expected_at_least_two_ingestion_requests_got_#{ingestion_requests.length}")

backend_request, log_event = find_event(ingestion_requests) do |event|
  event['event_type'] == 'log_event' && event.dig('payload', 'message') == 'ruby app-driven smoke message'
end

[log_event].each do |event|
  assert!(schemer.valid?(event), "schema_validation_failed_for_#{event['event_type']}")
end

assert!(
  backend_request.headers['authorization'] == "Bearer #{PROJECT_TOKEN}",
  'expected_backend_capture_to_use_server_project_token'
)
assert!(backend_request.headers['cookie'].nil?, 'backend_ingestion_should_not_forward_browser_cookie_headers')
assert!(log_event['sdk_name'] == '@debugbundle/sdk-ruby', 'unexpected_backend_sdk_name')
assert!(log_event['sdk_version'] == expected_version, 'unexpected_backend_sdk_version')
assert!(log_event.dig('service', 'name') == 'checkout-api', 'unexpected_backend_service_name')
assert!(log_event.dig('service', 'environment') == 'production', 'unexpected_backend_service_environment')
assert!(log_event.dig('correlation', 'trace_id') == BACKEND_TRACE_ID, 'backend_log_trace_id_not_preserved')
assert!(log_event.dig('correlation', 'request_id') == BACKEND_REQUEST_ID, 'backend_log_request_id_not_preserved')

relay_request, relay_event = find_event(ingestion_requests) do |event|
  event['event_type'] == 'frontend_exception' && event['sdk_name'] == '@debugbundle/sdk-browser'
end

assert!(schemer.valid?(relay_event), 'schema_validation_failed_for_frontend_exception')
assert!(
  relay_request.headers['authorization'] == "Bearer #{PROJECT_TOKEN}",
  'expected_relay_forward_to_use_server_project_token'
)
assert!(relay_request.headers['cookie'].nil?, 'relay_forward_should_not_include_browser_cookie_headers')
assert!(relay_event['project_token'] == PROJECT_TOKEN, 'relay_event_should_use_server_project_token')
assert!(relay_event['sdk_version'] == '0.1.0', 'relay_event_should_preserve_browser_sdk_version')
assert!(relay_event.dig('service', 'name') == BROWSER_SERVICE, 'relay_event_should_preserve_browser_service_name')
assert!(
  relay_event.dig('service', 'environment') == BROWSER_ENVIRONMENT,
  'relay_event_should_preserve_browser_service_environment'
)
assert!(relay_event.dig('correlation', 'trace_id') == RELAY_TRACE_ID, 'relay_event_trace_id_not_preserved')
assert!(relay_event.dig('correlation', 'request_id') == RELAY_REQUEST_ID, 'relay_event_request_id_not_preserved')

puts 'Ruby app-driven smoke passed.'
