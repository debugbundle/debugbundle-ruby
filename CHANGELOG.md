# Changelog

## 0.1.3

- Added `OPTIONS /debugbundle/browser` preflight handling and matching CORS headers for explicitly allowed split-host browser relay requests in the Rack and Rails relay surfaces.

## 0.1.0

- Initial standalone gem scaffold.
- Core singleton and instance client APIs.
- Redaction, buffering, suppression, local file transport, and HTTP transport foundation.
- Rack middleware, Sidekiq middleware, stdlib logger integration, capture policy parsing, probes, and browser relay support.
