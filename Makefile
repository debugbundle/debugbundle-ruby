SHELL := /bin/sh

RUBY_IMAGE ?= ruby:3.4.2
WORKDIR := /workspace
BUNDLE_GEMFILE ?= Gemfile
VERSION ?= $(shell ruby -e 'require "./lib/debugbundle/version"; print DebugBundle::VERSION')

DOCKER_RUN = docker run --rm -t \
	-v "$(CURDIR):$(WORKDIR)" \
	-w "$(WORKDIR)" \
	$(RUBY_IMAGE)

BUNDLE_ENV = BUNDLE_GEMFILE="$(BUNDLE_GEMFILE)"
EVIDENCE_COMPAT_SPECS = spec/client_evidence_spec.rb spec/client_delivery_spec.rb spec/evidence_wire_spec.rb spec/exception_evidence_spec.rb spec/before_send_spec.rb spec/relay_evidence_spec.rb

.PHONY: bundle-install test lint build shell compat-rack compat-rails compat-rails-8 compat-sidekiq compat
.PHONY: smoke smoke-installed
.PHONY: smoke-published
.PHONY: test-focused check-docker
.PHONY: sdk-safety-perf
sdk-safety-perf:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) ruby -Ilib perf/host_safety.rb

.PHONY: evidence-performance
evidence-performance:
	docker run --rm -v "$(CURDIR):$(WORKDIR):ro" -w "$(WORKDIR)" $(RUBY_IMAGE) ruby -Ilib perf/evidence_comparison.rb

check-docker:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle bundle exec rubocop && BUNDLE_PATH=vendor/bundle bundle exec rspec && gem build debugbundle.gemspec'

test-focused:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle SIMPLECOV_MINIMUM_COVERAGE=0 bundle exec rspec $(TEST_FILES)'

.PHONY: format-transport-tests
format-transport-tests:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle bundle exec rubocop -a spec/http_acknowledgement_spec.rb'

.PHONY: format-focused
format-focused:
	docker run --rm -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" $(RUBY_IMAGE) sh -lc 'BUNDLE_PATH=vendor/bundle bundle exec rubocop -a $(FORMAT_FILES)'

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

# Reuse one built artifact across native runtime lanes without mutating source.
smoke-installed:
	docker run --rm -v "$(CURDIR):$(WORKDIR):ro" -w "$(WORKDIR)" $(RUBY_IMAGE) ruby smoke/run_app_driven_smoke.rb --source local --version $(VERSION)

.PHONY: evidence-installed-matrix
evidence-installed-matrix:
	test -s "debugbundle-$(VERSION).gem"
	mkdir -p tmp/evidence-runtime
	@set -e; for version in 3.1.6 3.2 3.3 3.4.2 4.0; do \
	  $(MAKE) smoke-installed RUBY_IMAGE=ruby:$$version > tmp/evidence-runtime/installed-$$version.log 2>&1; \
	done

smoke-published:
	$(DOCKER_RUN) sh -lc "ruby smoke/run_app_driven_smoke.rb --source published --version $(VERSION)"

compat-rack:
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.1.6 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle exec rspec spec/rack_integration_spec.rb spec/rack_middleware_spec.rb spec/relay_spec.rb $(EVIDENCE_COMPAT_SPECS)'
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle exec rspec spec/rack_integration_spec.rb spec/rack_middleware_spec.rb spec/relay_spec.rb $(EVIDENCE_COMPAT_SPECS)'

compat-rails:
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.1.6 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb $(EVIDENCE_COMPAT_SPECS)'
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb $(EVIDENCE_COMPAT_SPECS)'

compat-rails-8:
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:4.0 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_8_1.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_8_1.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_8_1.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb spec/rack_middleware_spec.rb $(EVIDENCE_COMPAT_SPECS)'

compat-sidekiq:
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle exec rspec spec/sidekiq_middleware_spec.rb spec/sidekiq_integration_spec.rb $(EVIDENCE_COMPAT_SPECS)'
	docker run --rm -t -v "$(CURDIR):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle exec rspec spec/sidekiq_middleware_spec.rb spec/sidekiq_integration_spec.rb $(EVIDENCE_COMPAT_SPECS)'

compat: compat-rack compat-rails compat-rails-8 compat-sidekiq

shell:
	$(DOCKER_RUN) sh
