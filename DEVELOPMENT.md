# Development Guide

## Configuration Naming Conventions

This plugin aligns its configuration option names with the [Docker Compose Specification](https://compose-spec.io/) to provide a familiar API for users who work with `docker-compose.yml` files.

### Naming Alignment with Compose Spec

| Docker Compose field | Plugin YAML option | Environment variable | Purpose |
|-----|-----|-----|-----|
| `environment` | `environment` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT` | Environment variables for the container |
| `volumes` | `volumes` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES` | Volume mounts for the container |

### CLI Argument Options

Options not defined in the Compose spec follow CLI conventions:
- `file` - path to compose file(s) (matches `docker compose -f` flag)

### Example Configuration

```yaml
steps:
  - name: Run tests
    command: npm test
    plugins:
      - docker-compose-run#v3.0.0:
          file: docker-compose.yml
          service: app
          environment:
            - NODE_ENV=test
            - DEBUG=app:*
          volumes:
            - ./src:/app/src:ro
```

### Non-Spec Options

Options not defined in the Compose spec follow CLI conventions:
- `entrypoint` - override the service entrypoint
- `workdir` - working directory in the container

## Related Documentation

- [Docker Compose Specification](https://compose-spec.io/)
- [Plugin Configuration Reference](./README.md)
