# frozen_string_literal: true

require 'debugbundle'

Rails.application.configure do
  config.debugbundle.project_token = ENV.fetch('DEBUGBUNDLE_TOKEN', 'dbundle_proj_local')
  config.debugbundle.service = 'rails-checkout'
  config.debugbundle.environment = ENV.fetch('RAILS_ENV', Rails.env)
  config.debugbundle.project_mode = :local_only

  # The Railtie mounts POST /debugbundle/browser automatically unless disabled.
  config.debugbundle.relay_allowed_origins = ['http://localhost:3000']
  config.debugbundle.relay_path = '/debugbundle/browser'
  config.debugbundle.relay_durable_write = true
end
