# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'repository metadata' do
  let(:repo_root) { File.expand_path('..', __dir__) }

  def read_repository_file(path)
    File.read(File.join(repo_root, path))
  end

  it 'ships the smoke harness and wires it into workflows' do
    %w[
      Makefile
      smoke/run_app_driven_smoke.rb
      smoke/app_driven_smoke_runner.rb
      .github/workflows/ci.yml
      .github/workflows/release.yml
    ].each do |relative_path|
      expect(File).to exist(File.join(repo_root, relative_path))
    end

    makefile = read_repository_file('Makefile')
    ci_workflow = read_repository_file('.github/workflows/ci.yml')
    release_workflow = read_repository_file('.github/workflows/release.yml')

    [
      '.PHONY: smoke',
      '.PHONY: smoke-published',
      'smoke/run_app_driven_smoke.rb --source local',
      'smoke/run_app_driven_smoke.rb --source published --version $(VERSION)'
    ].each do |fragment|
      expect(makefile).to include(fragment)
    end

    expect(ci_workflow).to include('make smoke')
    expect(release_workflow).to include('make smoke')
    expect(release_workflow).to include('make smoke-published VERSION=${RELEASE_VERSION}')
  end

  it 'documents the Ruby release documentation gates in the README' do
    readme = read_repository_file('README.md')

    [
      '## Configuration Reference',
      'Configuration sources and precedence:',
      'Capture-policy fields are server-owned',
      '## Install Examples by Mode',
      '## Runtime and Framework Support',
      '## Dependency Alignment',
      '## Browser Relay',
      '## Service Naming',
      '## Safe Startup and Status',
      '## First-Event Verification',
      'make smoke',
      'same-origin',
      'allowed origins',
      'rate limiting',
      'credential isolation',
      'missing token'
    ].each do |fragment|
      expect(readme).to include(fragment)
    end
  end
end
