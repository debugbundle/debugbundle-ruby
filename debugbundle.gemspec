# frozen_string_literal: true

require_relative 'lib/debugbundle/version'

Gem::Specification.new do |spec|
  spec.name = 'debugbundle'
  spec.version = DebugBundle::VERSION
  spec.authors = ['DebugBundle']
  spec.email = ['support@debugbundle.com']

  spec.summary = 'DebugBundle SDK for Ruby'
  spec.description = 'Production-ready error, request, log, and probe capture for Ruby services.'
  spec.homepage = 'https://debugbundle.com/docs/sdks/ruby'
  spec.license = 'AGPL-3.0-only'
  spec.required_ruby_version = '>= 3.1'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => 'https://github.com/debugbundle/debugbundle-ruby',
    'changelog_uri' => 'https://github.com/debugbundle/debugbundle-ruby/blob/main/CHANGELOG.md',
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir.glob('{lib,spec}/**/*') + %w[Gemfile Makefile README.md debugbundle.gemspec]
  spec.bindir = 'exe'
  spec.require_paths = ['lib']

  spec.add_dependency 'base64', '~> 0.2'
  spec.add_dependency 'logger', '~> 1.6'
end
