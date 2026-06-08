# Changelog

## 1.1.0

- Added path-scoped immediate client-error incident promotion support in remote capture-policy handling so explicitly configured `4xx` routes can emit standalone `request_event` incident signals without widening the status globally.
- Unpromoted client-error request telemetry now remains context-only under repeated traffic, while `5xx` handling and explicitly promoted client-error behavior are preserved.

## 1.0.0

- Marked the first stable Ruby gem release after the client, Rack/Rails/Sidekiq integration, relay, and app-driven smoke surfaces settled across the supported lanes.

## 0.1.3

- Added `OPTIONS /debugbundle/browser` preflight handling and matching CORS headers for explicitly allowed split-host browser relay requests in the Rack and Rails relay surfaces.

## 0.1.0

- Initial standalone gem scaffold.
- Core singleton and instance client APIs.
- Redaction, buffering, suppression, local file transport, and HTTP transport foundation.
- Rack middleware, Sidekiq middleware, stdlib logger integration, capture policy parsing, probes, and browser relay support.
