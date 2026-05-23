# frozen_string_literal: true

require 'debugbundle'
require 'json'

DebugBundle.init(
  project_token: ENV.fetch('DEBUGBUNDLE_TOKEN', 'dbundle_proj_local'),
  service: 'rack-checkout',
  environment: ENV.fetch('RACK_ENV', 'development'),
  project_mode: :local_only
)

app = lambda do |_env|
  DebugBundle.capture_message('rack example request', level: :info)
  [200, { 'Content-Type' => 'application/json' }, [JSON.generate(ok: true)]]
end

run DebugBundle::Rack::Middleware.new(app, client: DebugBundle.client)
