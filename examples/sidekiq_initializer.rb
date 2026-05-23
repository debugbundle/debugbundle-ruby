# frozen_string_literal: true

require 'debugbundle'
require 'sidekiq'

DebugBundle.init(
  project_token: ENV.fetch('DEBUGBUNDLE_TOKEN', 'dbundle_proj_local'),
  service: 'sidekiq-worker',
  environment: ENV.fetch('APP_ENV', 'development'),
  project_mode: :local_only
)

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add(DebugBundle::Sidekiq::ServerMiddleware, client: DebugBundle.client)
  end
end
