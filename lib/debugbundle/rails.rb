# frozen_string_literal: true

begin
  require 'rails/railtie'
rescue LoadError
  nil
end

require_relative 'rails/relay_endpoint'
require_relative 'rails/railtie' if defined?(Rails::Railtie)
