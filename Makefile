SHELL := /bin/sh

RUBY_IMAGE ?= ruby:3.4.2
WORKDIR := /workspace
BUNDLE_GEMFILE ?= Gemfile
VERSION ?= $(shell ruby -e 'require "./lib/debugbundle/version"; print DebugBundle::VERSION')

DOCKER_RUN = docker run --rm -t \
	-v "$(PWD):$(WORKDIR)" \
	-w "$(WORKDIR)" \
	$(RUBY_IMAGE)

BUNDLE_ENV = BUNDLE_GEMFILE="$(BUNDLE_GEMFILE)"

.PHONY: bundle-install test lint build shell compat-rack compat-rails compat-rails-8 compat-sidekiq compat
.PHONY: smoke
.PHONY: smoke-published
.PHONY: test-focused check-docker
.PHONY: sdk-safety-perf
sdk-safety-perf:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) ruby -Ilib perf/host_safety.rb

check-docker:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle bundle exec rubocop && BUNDLE_PATH=vendor/bundle bundle exec rspec && gem build debugbundle.gemspec'

test-focused:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle SIMPLECOV_MINIMUM_COVERAGE=0 bundle exec rspec $(TEST_FILES)'

.PHONY: format-transport-tests
format-transport-tests:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle bundle exec rubocop -a spec/http_acknowledgement_spec.rb'

bundle-install:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install"

test:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install && $(BUNDLE_ENV) bundle exec rspec"

lint:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install && $(BUNDLE_ENV) bundle exec rubocop"

build:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install && gem build debugbundle.gemspec"

smoke:
	$(DOCKER_RUN) sh -lc "gem build debugbundle.gemspec && ruby smoke/run_app_driven_smoke.rb --source local --version $(VERSION)"

smoke-published:
	$(DOCKER_RUN) sh -lc "ruby smoke/run_app_driven_smoke.rb --source published --version $(VERSION)"

compat-rack:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.1.6 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle exec rspec spec/rack_integration_spec.rb spec/rack_middleware_spec.rb spec/relay_spec.rb'
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle exec rspec spec/rack_integration_spec.rb spec/rack_middleware_spec.rb spec/relay_spec.rb'

compat-rails:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.1.6 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb'
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb'

compat-rails-8:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:4.0 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_8_1.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_8_1.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_8_1.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb spec/rack_middleware_spec.rb'

compat-sidekiq:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle exec rspec spec/sidekiq_middleware_spec.rb spec/sidekiq_integration_spec.rb'
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle exec rspec spec/sidekiq_middleware_spec.rb spec/sidekiq_integration_spec.rb'

compat: compat-rack compat-rails compat-rails-8 compat-sidekiq

shell:
	$(DOCKER_RUN) sh
