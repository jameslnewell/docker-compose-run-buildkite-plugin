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
| `env` | array | — | Environment variables as `KEY=VALUE` |
| `volume` | array | — | Volume mounts as `host:container` |

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
          env:
            - DATABASE_URL=postgres://localhost/test
            - NODE_ENV=test

  - label: "Run with volume override"
    plugins:
      - jameslnewell/docker-compose-run#v1.0.0:
          service: web
          workdir: /app
          volume:
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
