# frozen_string_literal: true

require 'fileutils'
require 'optparse'
require 'tmpdir'

REPO_ROOT = File.expand_path('..', __dir__)
DEFAULT_SCHEMA_PATH = File.join(REPO_ROOT, 'spec/fixtures/event-envelope.schema.json')
PUBLISHED_INSTALL_ATTEMPTS = 12
PUBLISHED_INSTALL_RETRY_SECONDS = 10

def run_command!(env, *command)
  success = system(env, *command)
  return if success

  raise "command_failed: #{command.join(' ')}"
end

def install_published_gem!(env, version)
  attempts = 0

  loop do
    attempts += 1
    success = system(env, 'gem', 'install', '--no-document', 'debugbundle', '-v', version)
    return if success

    raise "published_gem_install_failed: #{version}" if attempts >= PUBLISHED_INSTALL_ATTEMPTS

    warn(
      "Published gem #{version} not available yet; retrying in " \
      "#{PUBLISHED_INSTALL_RETRY_SECONDS}s (attempt #{attempts}/#{PUBLISHED_INSTALL_ATTEMPTS})."
    )
    sleep(PUBLISHED_INSTALL_RETRY_SECONDS)
  end
end

options = {
  source: 'local',
  version: nil,
  schema: DEFAULT_SCHEMA_PATH
}

OptionParser.new do |parser|
  parser.on('--source SOURCE', 'local or published') { |value| options[:source] = value }
  parser.on('--version VERSION', 'Gem version to install or verify') { |value| options[:version] = value }
  parser.on('--schema PATH', 'Event envelope schema fixture') { |value| options[:schema] = value }
end.parse!

version = options[:version].to_s
raise '--version is required' if version.empty?

schema_path = File.expand_path(options[:schema], Dir.pwd)
raise "missing_schema: #{schema_path}" unless File.file?(schema_path)

source = options[:source].to_s
raise "unsupported_source: #{source}" unless %w[local published].include?(source)

artifact_path = File.join(REPO_ROOT, "debugbundle-#{version}.gem")
raise "missing_artifact: #{artifact_path}" if source == 'local' && !File.file?(artifact_path)

runner_path = File.join(REPO_ROOT, 'smoke/app_driven_smoke_runner.rb')

Dir.mktmpdir('debugbundle-ruby-smoke-') do |temp_dir|
  gem_home = File.join(temp_dir, 'gems')
  FileUtils.mkdir_p(gem_home)

  env = {
    'GEM_HOME' => gem_home,
    'GEM_PATH' => gem_home,
    'PATH' => "#{File.join(gem_home, 'bin')}:#{ENV.fetch('PATH')}",
    'DEBUGBUNDLE_EXPECTED_VERSION' => version,
    'DEBUGBUNDLE_SCHEMA_PATH' => schema_path
  }

  run_command!(env, 'gem', 'install', '--no-document', 'rack', 'json_schemer')

  if source == 'local'
    run_command!(env, 'gem', 'install', '--no-document', artifact_path)
  else
    install_published_gem!(env, version)
  end

  run_command!(env, 'ruby', runner_path)
end
