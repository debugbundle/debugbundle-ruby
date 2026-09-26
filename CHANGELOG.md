# Changelog

## [Unreleased]

## [2.0.1] - 2026-09-26

### Fixed

- Honor bounded retry hints after partial/malformed acknowledgements and service failures; accept HTTP-date hints. Preserve no-hint service-failure timing.
- Treat nonfinite HTTP and custom retry hints as missing, preserving finite backoff and recovery; clamp numeric headers before integer conversion.

- Require a valid canonical acknowledgement from built-in HTTP delivery; retain the full batch and back off for missing or malformed responses. Preserve bodyless file and explicit custom transport compatibility.

## [2.0.0] - 2026-09-25

### Changed

- Reject logs against local and remote levels before event construction or `before_send`; `capture_logs: off` excludes FATAL too.
- Run remote configuration on a separate bounded poller so a stalled config fetch cannot hold delivery. Run `before_send`, automatic batch/interval delivery, and local file or HTTP transport on one owned sender thread. Explicit `flush` waits at most five seconds for the sender and returns `false` if it cannot complete.
- Bound combined queued/in-flight ownership and cached hook replacements to 1,000 entries and 8 MiB. Held transport work cannot be displaced; exceptions and failed requests may evict only unsent lower-priority work. Emit bounded queue-pressure aggregates after capacity returns. A saturated all-ERROR or all-exception queue rejects excess records before reading their application messages or building events.
- Reinitialize the sender and discard inherited parent capture state after a fork. Automatic exception hooks wake the sender without waiting for stalled delivery.
- Read the stored exception type, message, backtrace, and cause through Ruby's built-in accessors so application overrides cannot block or raise through capture. Retain at most eight causes, 64 stack frames, and 16,384 stack characters per exception.
- Avoid application-defined `to_s` during accepted log capture. Strings and simple Ruby scalar messages retain their values; unsupported objects use a fixed placeholder.
- Avoid application-defined conversion for context keys and values and request-like objects on the capture caller. Unsupported context values use a fixed placeholder, unsupported keys are skipped, and request/response metadata requires a Hash. Bound path-rule normalization to 2,048 characters.
- Compile one bounded assignment matcher per privacy policy instead of scanning every text once per sensitive field. The full shared privacy corpus and every mandatory assignment label remain protected. Enforce filtered, accepted, configured-privacy, stalled-transport, concurrent-caller, and full-queue timing/resource budgets in CI and the package release workflow.
- See [MIGRATION-2.0.md](MIGRATION-2.0.md) for hook timing, explicit flush, and overload semantics.

## [1.5.0] - 2026-09-21

### Security

- Enforce mandatory bounded privacy checks across context, `before_send`, buffers, transport, and Rack or Rails browser relays. Application custom keys add to the baseline.

### Changed

- Keep Rack request capture compatible with Ruby 4.0 and Rails 8.1 after removal of `CGI.parse`, bound query parsing, and exclude test and development files from the built gem.

## [1.4.1] - 2026-09-15

### Fixed

- Respect stdlib Logger levels, disabled output and Rails silence. Capture `add` and `log` without evaluating lazy blocks when suppressed or evaluating accepted blocks twice.
- Preserve native output, return values, message values and application exceptions; isolate SDK callback failures and recursive logging.

## [1.4.0] - 2026-09-12

### Changed

- License first-party SDK code under Apache-2.0 and ship consistent package licensing metadata and license text.

## 1.3.0 - 2026-07-28

- Added the universal `before_send` event hook and canonical object wrapping for scalar/list probe values.
- Reconcile connected ingestion acknowledgements per event, retaining only retryable rejections and withholding delivery health when no event was accepted.
- Enforce the required 80% coverage floor for each source file.

## 1.2.0

- Corrected the semantic release line for browser-relay analytics support. Relay handlers accept credential-free `analytics_event` envelopes while preserving only the required analytics correlation fields and stripping browser-supplied credentials.

## 1.1.3

- Accepted canonical browser `analytics_event` envelopes through the Rack and Rails relay while retaining the existing validation, origin controls, rate limits, and durable delivery semantics.

## 1.1.2

- Release quality gates so the published Ruby SDK patch ships cleanly without changing runtime behavior.

## 1.1.1

- Normalized canonical event-envelope emission so custom app context now stays in envelope `context`, request events avoid legacy payload extras, and installed projects stop tripping malformed ingestion rejects after upgrade.

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
