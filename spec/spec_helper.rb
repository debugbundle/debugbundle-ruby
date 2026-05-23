# frozen_string_literal: true

require 'simplecov'

SimpleCov.start do
  add_filter '/spec/'

  minimum_coverage_threshold = ENV.fetch('SIMPLECOV_MINIMUM_COVERAGE', '80').to_i
  minimum_coverage minimum_coverage_threshold if minimum_coverage_threshold.positive?
end

require 'debugbundle'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = '.rspec_status'
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
end
