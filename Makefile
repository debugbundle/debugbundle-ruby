SHELL := /bin/sh

RUBY_IMAGE ?= ruby:3.4.2
WORKDIR := /workspace
BUNDLE_GEMFILE ?= Gemfile

DOCKER_RUN = docker run --rm -t \
	-v "$(PWD):$(WORKDIR)" \
	-w "$(WORKDIR)" \
	$(RUBY_IMAGE)

BUNDLE_ENV = BUNDLE_GEMFILE="$(BUNDLE_GEMFILE)"

.PHONY: bundle-install test lint build shell compat-rack compat-rails compat-sidekiq compat

bundle-install:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install"

test:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install && $(BUNDLE_ENV) bundle exec rspec"

lint:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install && $(BUNDLE_ENV) bundle exec rubocop"

build:
	$(DOCKER_RUN) sh -lc "$(BUNDLE_ENV) bundle config set path vendor/bundle && $(BUNDLE_ENV) bundle install && gem build debugbundle.gemspec"

compat-rack:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.1.6 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_2_2.gemfile" bundle exec rspec spec/rack_integration_spec.rb spec/rack_middleware_spec.rb spec/relay_spec.rb'
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rack_3.gemfile" bundle exec rspec spec/rack_integration_spec.rb spec/rack_middleware_spec.rb spec/relay_spec.rb'

compat-rails:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.1.6 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_0.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb'
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/rails_7_1.gemfile" bundle exec rspec spec/rails_relay_spec.rb spec/rails_railtie_spec.rb'

compat-sidekiq:
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_7.gemfile" bundle exec rspec spec/sidekiq_middleware_spec.rb spec/sidekiq_integration_spec.rb'
	docker run --rm -t -v "$(PWD):$(WORKDIR)" -w "$(WORKDIR)" ruby:3.4.2 sh -lc 'SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle config set path vendor/bundle && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle install && SIMPLECOV_MINIMUM_COVERAGE=0 BUNDLE_GEMFILE="gemfiles/sidekiq_8.gemfile" bundle exec rspec spec/sidekiq_middleware_spec.rb spec/sidekiq_integration_spec.rb'

compat: compat-rack compat-rails compat-sidekiq

shell:
	$(DOCKER_RUN) sh
