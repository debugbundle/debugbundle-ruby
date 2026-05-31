# debugbundle

Ruby SDK for DebugBundle.

Use this gem to capture Ruby backend exceptions, request metadata, structured logs, runtime context, probe data, and browser relay traffic. It supports a singleton facade plus instance clients for Rack, Rails, Sidekiq, and explicit Ruby instrumentation.

## Installation

```ruby
gem "debugbundle"
```

## Quick Start

```ruby
require "debugbundle"
require "logger"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-api",
  environment: ENV.fetch("APP_ENV", "production")
)

DebugBundle.capture_logger(Logger.new($stdout))

begin
  perform_checkout
rescue => error
  DebugBundle.capture_exception(error, context: { order_id: 123 })
end

DebugBundle.capture_message("worker started", level: :info)
DebugBundle.flush
```

`DebugBundle.init(...)` arms best-effort process exception capture automatically through `at_exit` and thread exception hooks.

## Framework Integrations

| Surface | Integration |
| --- | --- |
| Rack | `DebugBundle::Rack::Middleware` |
| Rails | Railtie bootstrap, Rack middleware, and auto-mounted relay route |
| Sidekiq | `DebugBundle::Sidekiq::ServerMiddleware` |
| Ruby Logger | `DebugBundle.capture_logger(logger)` |
| Semantic Logger | `DebugBundle.capture_semantic_logger` |
| Browser relay | `DebugBundle::Relay::Handler` or `DebugBundle::Rack::RelayMiddleware` |

## Configuration Reference

Configuration sources and precedence:

1. Explicit arguments passed to `DebugBundle.init(...)`, `DebugBundle::Client.new(...)`, or `DebugBundle::Relay::Handler.new(...)`.
2. Rails `config.debugbundle.*` values when the Railtie wires the default client or relay route.
3. Environment variables only when your application chooses to pass them into those explicit Ruby calls. The gem does not auto-read arbitrary config env vars on its own.
4. Remote probe directives and capture policy returned by `GET /v1/sdk/config` after a connected client initializes.

Capture-policy fields are server-owned and must not be supplied in local SDK config. The Ruby SDK enforces the server response locally after initialization.

| Option | Default | Purpose |
| --- | --- | --- |
| `project_token` | required for connected capture | Write-only DebugBundle project token used by server-side transport. |
| `service` | `ruby-service` | Service name used in event envelopes. |
| `environment` | `development` | Runtime environment. |
| `endpoint` | `https://api.debugbundle.com/v1/events` | Connected ingestion endpoint. |
| `enabled` | `true` | Disable all capture without removing instrumentation. |
| `project_mode` | `connected` | `connected` or `local_only`. |
| `local_events_dir` | `.debugbundle/local/events` | Local event file destination. |
| `spool_dir` | `.debugbundle/local/browser-relay-spool` | Relay durable spool destination. |
| `redact_fields` | `[]` | Additional sensitive field names merged with built-in redaction defaults. Rails `filter_parameters` are added automatically. |
| `batch_size` | `25` | Max events per flush batch. |
| `flush_interval` | `5` | Flush interval in seconds. |
| `sample_rate` | `1.0` | Fraction of events kept before transport. |
| `log_level` | `warning` | Minimum captured log severity. |
| `relay_enabled` | `true` | Enable relay handling when using the Rails helper surface. |
| `relay_rate_limit_per_minute` | `60` | Per-IP rate limit for browser relay requests. |
| `relay_durable_write` | `true` | Write relay batches to the local spool before connected forwarding. |
| `max_probe_labels` | `50` | Max distinct probe labels kept in memory. |
| `max_probe_entries_per_label` | `10` | Max entries retained per probe label. |
| `probe_flush_on_error` | `true` | Attach probe buffers to captured exceptions. |
| `probes_poll_interval` | `60` | Remote config poll interval in seconds. |

## Install Examples by Mode

### Connected mode

```ruby
require "debugbundle"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-api",
  environment: "production",
  endpoint: "https://api.debugbundle.com/v1/events"
)
```

### Local-only mode

```ruby
require "debugbundle"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-api",
  environment: "development",
  project_mode: :local_only,
  local_events_dir: ".debugbundle/local/events"
)
```

### Rack middleware

```ruby
require "debugbundle"
require "rack"

client = DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-api",
  environment: "production"
)

app = Rack::Builder.new do
  use DebugBundle::Rack::Middleware, client: client

  run lambda { |_env|
    [200, { "Content-Type" => "text/plain" }, ["ok"]]
  }
end
```

### Rails initializer

```ruby
# config/initializers/debugbundle.rb
require "debugbundle"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-api",
  environment: Rails.env
)

Rails.application.configure do
  config.debugbundle.relay_allowed_origins = ["https://app.example.com"]
end
```

### Sidekiq server middleware

```ruby
require "debugbundle"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-worker",
  environment: ENV.fetch("APP_ENV", "production")
)

Sidekiq.configure_server do |config|
  config.server_middleware do |chain|
    chain.add(DebugBundle::Sidekiq::ServerMiddleware, client: DebugBundle.client)
  end
end
```

### Logger integration

```ruby
require "debugbundle"
require "logger"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "checkout-api"
)

logger = Logger.new($stdout)
DebugBundle.capture_logger(logger)
```

## Runtime and Framework Support

| Surface | Minimum compatibility version | Recommended production version | Installed-base compatibility lane | Rolling CI lane | Out of scope |
| --- | --- | --- | --- | --- | --- |
| Ruby runtime | 3.1 | current maintained Ruby 3.4.x patch line | 3.1 and 3.2 remain supported for installed-base coverage | 3.1, 3.2, 3.3, 3.4 | 3.0 and older |
| Rails | 7.0 | latest 7.1 patch line | 7.0 compatibility support | 7.0 and 7.1 | 6.x and older |
| Rack | 2.2 | latest 3.x patch line | 2.2 compatibility support | 2.2 and 3.x | 2.1 and older |
| Sidekiq | 7.x | latest 8.x patch line | 7.x compatibility support | 7.x and 8.x | 6.x and older |

Post-V1 integrations remain out of scope here: Resque, Delayed Job, GoodJob, Sneakers, Shoryuken, Sinatra, Hanami, and deep ActiveRecord or SQL auto-instrumentation.

## Dependency Alignment

`debugbundle` ships as one gem in V1, so there is no multi-package version-alignment surface like an npm family rule or Maven BOM.

- Pin one `debugbundle` version across your Ruby web app and worker repos when you want identical SDK behavior everywhere.
- Keep Rack, Rails, and Sidekiq inside the supported lanes above.
- Do not mix unsupported framework majors into examples or deployment templates.

## Browser Relay

Ruby backends can receive browser events at `POST /debugbundle/browser` through the relay handler.

Rails applications can let the Railtie append that route automatically, or override it with:

- `config.debugbundle.relay_enabled = false` to disable automatic mounting
- `config.debugbundle.relay_path = "/debugbundle/browser"` to change the mounted path
- `config.debugbundle.relay_allowed_origins = ["https://app.example.com"]` to pin allowed origins
- `config.debugbundle.relay_rate_limit_per_minute = 120` to adjust per-IP rate limiting
- `config.debugbundle.relay_rate_limit_store = Rails.cache` to share rate limiting across processes
- `config.debugbundle.relay_handler = custom_handler` to supply a custom relay handler

Rack applications can mount the same handler explicitly:

```ruby
relay_handler = DebugBundle::Relay::Handler.new(
  project_mode: :connected,
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  endpoint: "https://api.debugbundle.com/v1/events",
  allowed_origins: ["https://app.example.com"]
)

use DebugBundle::Rack::RelayMiddleware, handler: relay_handler
```

Relay behavior:

- same-origin is the safe default when you do not set explicit allowed origins
- use explicit allowed origins when the frontend and backend live on different hosts
- requests must use `Content-Type: application/json`
- request bodies are capped at 256 KB
- per-IP rate limiting defaults to 60 requests per minute
- browser-supplied DebugBundle credentials are stripped before delivery, preserving credential isolation
- browser `service`, `environment`, and correlation fields are preserved unless you explicitly override them in the relay handler
- local-only mode writes validated browser events to `.debugbundle/local/events`
- connected durable mode writes validated browser events to `.debugbundle/local/browser-relay-spool` before forwarding to the configured endpoint
- set `relay_durable_write: false` when you intentionally want connected forwarding without the local spool write
- to disable the relay entirely, leave the route unmounted or set `relay_enabled = false`
- a missing token means connected forwarding cannot succeed; treat that as a server config error and leave the route disabled until the server-side token is fixed

## Remote Probes

Probe buffers stay local and flush on captured exceptions by default. Paid-tier projects can also activate probes for immediate `probe_event` shipping through the polled remote config.

For one-off request diagnostics, the Ruby SDK also accepts signed trigger tokens:

- header: `X-DebugBundle-Probe-Trigger: dbundle_probe_...`
- query parameter: `?_debug_probe=dbundle_probe_...`

Matching probes still stay in the local ring buffer, but the triggered request also emits standalone `probe_event` records immediately when the token is valid.

## Safety Defaults

- SDK failures are isolated from host application failures.
- Sensitive values are redacted before buffering or transport.
- Rails `filter_parameters` are merged into redaction automatically.
- Duplicate event storms are suppressed locally.
- Request headers use an allowlist by default.
- Local file writes use owner-only permissions.
- `development`, `local`, and `test` environments write local event files by default.
- Browser relay requests cannot smuggle server-side credentials.

## Service Naming

Use distinct service names when one DebugBundle project receives events from multiple deployables:

- Browser frontend: `checkout-web`
- Rails or Rack API: `checkout-api`
- Sidekiq worker: `checkout-worker`

The Ruby relay preserves the browser-provided service name and environment by default. Only override relay-level `service` or `environment` when you intentionally want the backend relay host to rewrite browser event identity.

## Safe Startup and Status

The SDK never raises host-facing exceptions because of missing config, bad transport responses, or malformed remote config payloads.

- `DebugBundle.init(project_token: "")` leaves capture disabled and `DebugBundle.status` reports `:degraded`
- `DebugBundle.init(enabled: false)` keeps the SDK as a no-op and `DebugBundle.status` reports `:disconnected`
- `DebugBundle.last_event_at` stays `nil` until a successful flush completes
- `DebugBundle.flush` is a no-op when the SDK has no buffered events, no transport, or is still waiting out a retry window

Status meanings:

- `:healthy` — idle or the last flush succeeded
- `:degraded` — missing token or a temporary rate-limit window is preventing immediate delivery
- `:disconnected` — the SDK is disabled or repeated transport failures exhausted the connection path

The release rule here is fail-safe, not fail-open: connected mode with a missing token must never pretend capture is healthy.

## First-Event Verification

Use an explicit test message or exception during setup:

```ruby
require "debugbundle"

DebugBundle.init(
  project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
  service: "debugbundle-first-event",
  environment: "staging"
)

DebugBundle.capture_message("debugbundle first-event verification", level: :error)
DebugBundle.flush
puts [DebugBundle.status, DebugBundle.last_event_at].inspect
```

Then confirm the event through your mock ingestion endpoint, a staging project, or the DebugBundle CLI verification flow.

This repository also ships a clean-install app-driven smoke harness that validates the built gem and the published gem path:

```sh
make smoke
make smoke-published VERSION=1.0.0
```

`make smoke` builds the gem, installs it into a fresh RubyGems home, drives a Rack request plus a browser relay batch through the public SDK surface, validates event envelope shape, and confirms the mock ingestion endpoint receives the expected service, environment, SDK metadata, and correlation fields.

## Examples

- Rack app: [examples/rack_app.rb](examples/rack_app.rb)
- Rails initializer: [examples/rails_initializer.rb](examples/rails_initializer.rb)
- Sidekiq server setup: [examples/sidekiq_initializer.rb](examples/sidekiq_initializer.rb)

## Development

The project defaults to Docker-backed commands:

```sh
make bundle-install
make test
make compat
make lint
make build
make smoke
```

CI validates RSpec, RuboCop, compatibility lanes, gem build, and the clean-install smoke harness.

## Release

The repository ships a GitHub Actions release workflow at `.github/workflows/release.yml`.

- Push a `v*` tag or run the workflow manually with a `version` input.
- Configure the `RUBYGEMS_API_KEY` repository secret before enabling publish.
- The workflow runs lint, tests, gem build, `make smoke`, RubyGems publish, and `make smoke-published VERSION=<tag>` before creating the GitHub release.

## Documentation

- Ruby SDK docs: https://debugbundle.com/docs/sdks/ruby
- SDK overview: https://debugbundle.com/docs/sdks
- Browser relay: https://debugbundle.com/docs/sdks/browser-relay
- Repository: https://github.com/debugbundle/debugbundle-ruby

## License

AGPL-3.0-only. See LICENSE.
