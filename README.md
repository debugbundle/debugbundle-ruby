# debugbundle

Ruby SDK for DebugBundle.

Use this gem to capture Ruby backend exceptions, request metadata, structured logs, runtime context, probe data, and browser relay traffic. It supports a singleton facade plus instance clients for Rack, Rails, Sidekiq, and explicit Ruby instrumentation.

## Installation

```ruby
gem "debugbundle"
```

## Quick start

```ruby
require "debugbundle"

DebugBundle.init(
	project_token: ENV.fetch("DEBUGBUNDLE_TOKEN"),
	service: "checkout-api",
	environment: ENV.fetch("APP_ENV", "production")
)

DebugBundle.capture_logger(Logger.new($stdout))
```

`DebugBundle.init(...)` arms best-effort process exception capture automatically through `at_exit` and thread exception hooks.

Capture handled exceptions, messages, requests, and probes explicitly:

```ruby
begin
	perform_checkout
rescue => error
	DebugBundle.capture_exception(error, context: { order_id: 123 })
end

DebugBundle.capture_log("payment retry failed", level: :warning, context: { order_id: 123 })
DebugBundle.capture_message("worker started", level: :info)
DebugBundle.probe("checkout.tax", { region: "us-east-1" })
DebugBundle.flush
```

## Framework integrations

| Surface | Integration |
| --- | --- |
| Rack | `DebugBundle::Rack::Middleware` |
| Rails | Railtie bootstrap, Rack middleware, and auto-mounted relay route |
| Sidekiq | `DebugBundle::Sidekiq::ServerMiddleware` |
| Ruby Logger | `DebugBundle.capture_logger(logger)` |
| Semantic Logger | `DebugBundle.capture_semantic_logger` |
| Browser relay | `DebugBundle::Relay::Handler` or `DebugBundle::Rack::RelayMiddleware` |

## Browser relay

Ruby backends can receive browser events at `POST /debugbundle/browser` through the relay handler.

Rails applications can let the Railtie append that route automatically, or override it with:

- `config.debugbundle.relay_enabled = false` to disable automatic mounting
- `config.debugbundle.relay_path = "/debugbundle/browser"` to change the mounted path
- `config.debugbundle.relay_allowed_origins = ["https://app.example.com"]` to pin allowed origins
- `config.debugbundle.relay_rate_limit_per_minute = 120` to adjust per-IP relay throttling
- `config.debugbundle.relay_rate_limit_store = Rails.cache` to share relay throttling across processes
- `config.debugbundle.relay_handler = custom_handler` to supply a custom relay handler

The relay:

- validates same-origin requests by default
- enforces `Content-Type: application/json`
- caps request bodies at 256 KB
- strips browser-supplied credentials and trust-sensitive fields
- preserves browser correlation fields such as `trace_id`
- supports local-only event writes and connected durable forwarding

## Remote probes

Probe buffers stay local and flush on captured exceptions by default. Paid-tier projects can also activate probes for immediate `probe_event` shipping through the polled remote config.

For one-off request diagnostics, the Ruby SDK also accepts signed trigger tokens:

- header: `X-DebugBundle-Probe-Trigger: dbundle_probe_...`
- query parameter: `?_debug_probe=dbundle_probe_...`

Matching probes still stay in the local ring buffer, but the triggered request also emits standalone `probe_event` records immediately when the token is valid.

## Configuration

| Option | Default | Purpose |
| --- | --- | --- |
| `project_token` | required | Write-only DebugBundle project token. |
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

## Safety defaults

- SDK failures are isolated from host application failures.
- Sensitive values are redacted before buffering or transport.
- Rails `filter_parameters` are merged into redaction automatically.
- Duplicate event storms are suppressed locally.
- Request headers use an allowlist by default.
- Local file writes use owner-only permissions.
- `development`, `local`, and `test` environments write local event files by default.
- Browser relay requests cannot smuggle server-side credentials.

## Examples

- Rack app: [examples/rack_app.rb](examples/rack_app.rb)
- Rails initializer: [examples/rails_initializer.rb](examples/rails_initializer.rb)
- Sidekiq server setup: [examples/sidekiq_initializer.rb](examples/sidekiq_initializer.rb)

## Local development

The project defaults to Docker-backed commands:

```sh
make bundle-install
make test
make compat
make lint
make build
```

Compatibility lanes are also exercised in CI for Rails 7.0 and 7.1, Rack 2.2 and 3.x, and Sidekiq 7.x and 8.x.

## Release

The repository ships a GitHub Actions release workflow at `.github/workflows/release.yml`.

- Push a `v*` tag or run the workflow manually with a `version` input.
- Configure the `RUBYGEMS_API_KEY` repository secret before enabling publish.
- The workflow runs lint, tests, gem build, local smoke install, GitHub release creation, RubyGems publish, and a published-gem smoke install.

## Supported targets

- Ruby 3.1+
- Rails 7.0+
- Rack 2.2+
- Sidekiq 7.x+

## Documentation

- Ruby SDK docs: https://debugbundle.com/docs/sdks/ruby
- SDK overview: https://debugbundle.com/docs/sdks
- Browser relay: https://debugbundle.com/docs/sdks/browser-relay
- Repository: https://github.com/debugbundle/debugbundle-ruby

## License

AGPL-3.0-only. See LICENSE.
