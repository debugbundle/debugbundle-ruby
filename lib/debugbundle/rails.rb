# frozen_string_literal: true

begin
  require 'rails/railtie'
# The gem is intentionally usable without Rails; this branch is exercised by
# the clean non-Rails gem smoke rather than the Rails-enabled coverage process.
# :nocov:
rescue LoadError
  nil
end
# :nocov:

require_relative 'rails/relay_endpoint'
require_relative 'rails/railtie' if defined?(Rails::Railtie)
