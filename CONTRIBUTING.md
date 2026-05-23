# Contributing

## Development workflow

The Ruby SDK is a standalone repository and should be developed with Docker-backed commands by default.

```sh
make bundle-install
make test
make lint
make build
```

## Change expectations

- Keep changes small and behavior-focused.
- Add or update tests with every behavior change.
- Preserve the shared DebugBundle SDK contract across languages.
- Do not weaken privacy defaults or safety guarantees.

## Pull requests

- Explain the user-visible or contract-visible change.
- Call out any requirements or acceptance criteria covered.
- Include verification notes for tests, lint, and gem build.
