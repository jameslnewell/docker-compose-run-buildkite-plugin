# Development Guide

## Configuration Naming Conventions

This plugin aligns its configuration option names with the [Docker Compose Specification](https://compose-spec.io/) to provide a familiar API for users who work with `docker-compose.yml` files.

### Naming Alignment with Compose Spec

| Docker Compose field | Plugin YAML option | Environment variable | Purpose |
|-----|-----|-----|-----|
| `environment` | `environment` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT` | Environment variables for the container |
| `volumes` | `volumes` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES` | Volume mounts for the container |
| `entrypoint` | `entrypoint` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT` | Override the service's entrypoint |
| `command` | `command` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND` | Argv passed as the service's command |

### Non-Spec Options

Options not defined in the Compose spec follow either the Docker CLI's naming or the official [`docker-compose` Buildkite plugin](https://github.com/buildkite-plugins/docker-compose-buildkite-plugin)'s naming, so users moving between plugins don't have to relearn them:

| Plugin YAML option | Environment variable | Purpose |
|-----|-----|-----|
| `service` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE` | Service to run |
| `file` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE` | Compose file(s), matching `docker compose -f` |
| `workdir` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_WORKDIR` | Working directory in the container |
| `shell` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL` | Shell used to wrap the step's command |
| `propagate-aws` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_PROPAGATE_AWS` | Propagate AWS credential and region env vars |
| `propagate-buildkite-environment` | `BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_PROPAGATE_BUILDKITE_ENVIRONMENT` | Propagate `CI`, `BUILDKITE` and `BUILDKITE_*` |

Array options are read with `plugin_read_list` in [`lib/shared.bash`](./lib/shared.bash), which reads the `_0`, `_1`, … indexed variables the agent exports for YAML arrays and falls back to the unindexed variable for scalars.

### Compose feature detection

`hooks/command` probes `docker compose <subcommand> --help` for `--progress`, `pull --include-deps`, `up --pull` and `run --pull` rather than parsing a version number, so the plugin works across the Compose versions in the wild without a hard floor. `--pull never` is only added to `up`/`run` when the pull phase actually ran, since `up --scale <service>=0` never pulls the target's own image.

## Testing

Run the full suite the same way CI does — the [`buildkite/plugin-tester`](https://github.com/buildkite-plugins/buildkite-plugin-tester) image bundles bats and its helper libraries:

```bash
docker run --rm -v "$PWD:/plugin:ro" buildkite/plugin-tester
```

To run [bats](https://github.com/bats-core/bats-core) directly on macOS, install the helpers first — the unit tests stub Docker Compose and need [bats-support](https://github.com/bats-core/bats-support), [bats-assert](https://github.com/bats-core/bats-assert) and [bats-mock](https://github.com/buildkite-plugins/bats-mock):

```bash
brew tap bats-core/bats-core
brew install bash bats-core bats-core/bats-core/bats-support bats-core/bats-core/bats-assert
# bats-mock is not in Homebrew — clone it alongside the others:
git clone https://github.com/buildkite-plugins/bats-mock "$(brew --prefix)/lib/bats-mock"
```

Unit tests (no Docker required):

```bash
PATH="$(brew --prefix)/bin:$PATH" BATS_LIB_PATH="$(brew --prefix)/lib" bats tests/command.bats tests/pre-exit.bats
```

Integration tests (requires Docker and Docker Compose):

```bash
bats tests/integration.bats
```

## Releasing

1. Merge all changes to `main`
2. Go to **Actions → Create Release → Run workflow**
3. Enter the version (e.g. `v0.15.0`) and click **Run workflow**

The workflow will tag the commit, push the tag, and create a GitHub release with an auto-generated changelog.

## Related Documentation

- [Docker Compose Specification](https://compose-spec.io/)
- [Plugin Configuration Reference](./README.md)
