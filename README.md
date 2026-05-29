# Docker Compose Run Buildkite Plugin

Buildkite plugin to run a docker compose service with phase-level timing and automatic cleanup.

This plugin breaks execution into three separate log groups so each phase's time is visible in Buildkite:
1. **Pull images** — fetches all required images
2. **Start dependencies** — brings up dependent services (excluding the target service)
3. **Run** — executes the target service with specified overrides

All resources are cleaned up automatically, even on failure.

## Requirements

- Docker 25+
- Docker Compose 2.9+
- Buildkite Agent

## Configuration

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `file` | string or array | — | Docker compose file(s) to use. Defaults to `docker-compose.yml` |
| `service` | string | ✓ | Service to run |
| `workdir` | string | — | Override working directory in the container |
| `entrypoint` | string | — | Override container entrypoint |
| `environment` | array | — | Environment variables as `KEY=VALUE` |
| `volumes` | array | — | Volume mounts as `host:container` |

## Usage

Add to your `pipeline.yml`:

```yaml
steps:
  - label: "Run tests"
    plugins:
      - jameslnewell/docker-compose-run#v1.0.0:
          service: test
          file: docker-compose.yml

  - label: "Run with custom environment"
    plugins:
      - jameslnewell/docker-compose-run#v1.0.0:
          service: app
          file:
            - docker-compose.yml
            - docker-compose.test.yml
          environment:
            - DATABASE_URL=postgres://localhost/test
            - NODE_ENV=test

  - label: "Run with volume override"
    plugins:
      - jameslnewell/docker-compose-run#v1.0.0:
          service: web
          workdir: /app
          volumes:
            - ./src:/app/src
```

## How It Works

1. **Pull Phase** — Executes `docker compose pull` to fetch all required images
2. **Up Phase** — Executes `docker compose up --wait --scale service=0` to start dependencies without starting the target service
3. **Run Phase** — Executes `docker compose run --no-deps --rm` with any configured overrides
4. **Cleanup Phase** — Always runs `docker compose down --volumes --remove-orphans` and collects logs as artifacts

Each phase is visible as a separate log group in Buildkite, allowing you to see where time is being spent.

## Other plugins that may be useful

- [docker-run](https://github.com/jameslnewell/docker-run-buildkite-plugin) — Run a command in a Docker image with phase-level timing and automatic cleanup
- [docker-compose-build](https://github.com/jameslnewell/docker-compose-build-buildkite-plugin) — Build and push a docker compose service using `docker buildx bake`

## Testing

Tests are written using [bats](https://github.com/bats-core/bats-core). The unit tests stub Docker Compose commands and require [bats-support](https://github.com/bats-core/bats-support), [bats-assert](https://github.com/bats-core/bats-assert), and [bats-mock](https://github.com/buildkite-plugins/bats-mock).

Install the dependencies (macOS):

```bash
brew tap bats-core/bats-core
brew install bash bats-core bats-core/bats-core/bats-support bats-core/bats-core/bats-assert
# bats-mock is not in Homebrew — clone it alongside the others:
git clone https://github.com/buildkite-plugins/bats-mock "$(brew --prefix)/lib/bats-mock"
```

Run the unit tests (no Docker required):

```bash
PATH="$(brew --prefix)/bin:$PATH" BATS_LIB_PATH="$(brew --prefix)/lib" bats tests/command.bats tests/pre-exit.bats
```

Run the integration tests (requires Docker and Docker Compose):

```bash
bats tests/integration.bats
```
