# Docker Compose Run Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/plugins) that runs a step's command in a Docker Compose service, with phase-level timing and automatic cleanup.

Each phase (pull, up, run) is a separate log group in Buildkite, so it's easy to see where the time went. The project is torn down on exit — even when the command fails — and the service logs are uploaded as an artifact first.

## Requirements

- The `docker` CLI with the Compose v2 plugin (`docker compose`) available to the Buildkite agent. Flags that vary across Compose versions (`pull --include-deps`, `up --pull`, `run --pull`, `--progress`) are feature-detected, and the plugin degrades gracefully when they're missing.
- The `buildkite-agent` CLI on `PATH`, used to upload the service logs during cleanup.
- **Bash 3.2 or newer** on the agent. That covers every bash still in use — macOS ships 3.2, and Amazon Linux 2 and CentOS 7 ship 4.2 — so no agent should need a bash upgrade to run this plugin.

## Usage

Run the step's command in a service. By default the command is wrapped in `/bin/sh -e -c`, so multi-line scripts, pipes and `&&` all work:

```yaml
steps:
  - command: npm test
    plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: test
```

Layer multiple compose files and override the environment:

```yaml
steps:
  - command: npm test
    plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: app
          file:
            - docker-compose.yml
            - docker-compose.test.yml
          environment:
            - DATABASE_URL=postgres://db/test
            - NODE_ENV=test
```

Run a command defined by the plugin instead of the step. Each array item is one argv token — there is no shell, so `&&`, pipes and globs are not interpreted:

```yaml
steps:
  - plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: app
          command: ["npx", "prisma", "migrate", "deploy"]
```

A single array item may span multiple lines, so a whole script can be handed to a shell. Name the shell with the `shell` option and the script is the only thing left in `command`:

```yaml
steps:
  - plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: terraform
          shell: ["/bin/sh", "-ec"]
          command:
            - |
              cd terraform/production
              terraform init
              terraform plan
```

Naming the shell inside `command` works too — `command: ["/bin/sh", "-ec", "<script>"]` — but the `shell` option is what the official `docker` plugin uses, and it keeps the two concerns apart.

Mount extra paths and override the working directory:

```yaml
steps:
  - command: npm run build
    plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: web
          workdir: /app
          volumes:
            - ./src:/app/src
```

Give the service AWS credentials and the build's Buildkite environment:

```yaml
steps:
  - command: ./scripts/deploy.sh
    plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: deploy
          propagate-aws: true
          propagate-buildkite-environment: true
```

Copy the command's output out of the run container and onto the agent, where a later plugin can pick it up, without mounting anything into the container:

```yaml
steps:
  - command: npm test
    plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: test
          copy-out:
            - coverage:backend/coverage
      - artifacts#v1.10.0:
          upload: "backend/coverage/**/*"
```

`copy-out` is newer than `v0.16.0`, so pin a release that includes it. An older release copies nothing. See [Copying output out](#copying-output-out) for how the two paths are resolved.

Keep the stopped run container until the job ends, so a `post-command` hook can copy output out of it instead of the step mounting a directory into the container:

```yaml
steps:
  - plugins:
      - jameslnewell/docker-compose-run#v0.14.1:
          service: test
          rm: false
```

`rm` is newer than `v0.15.0`, so pin a release that includes it. An older release still removes the container at exit, and the guard below then skips the copy without failing the step.

A repository hook runs for every job in the pipeline, so guard it on the container existing. Otherwise it fails steps that don't use this plugin, that keep the default `rm: true`, or that failed before the run started:

```bash
# .buildkite/hooks/post-command
container="docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"
if docker container inspect "$container" >/dev/null 2>&1; then
  docker cp "${container}:/app/coverage" coverage
fi
```

## Configuration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `service` | string | — | **Required.** Compose service to run. |
| `file` | string or array | Compose's own file discovery (`compose.yaml`, `docker-compose.yml`, …) | Compose file(s), passed through as `-f`. Later files override earlier ones, as they do on the CLI. |
| `command` | array | — | Argv passed as the service's command. Each array item is one token, and an item may span multiple lines. Not wrapped in a shell unless `shell` names one. Cannot be combined with the step's `command`. |
| `shell` | array or boolean | `["/bin/sh", "-e", "-c"]` for the step's command; none for the plugin's `command` | Shell to wrap the command in. Setting it explicitly wraps the plugin's `command` too, which is how a multi-line script is run. Set to `false` to pass the step's command through unwrapped. |
| `workdir` | string | the service's | Working directory inside the container, passed as `--workdir`. |
| `entrypoint` | string | the service's | Override the service's entrypoint. Any value — including `""` — suppresses the *default* shell wrapping; setting `shell` explicitly turns it back on. Matches the official `docker` plugin. Use `""` to clear an entrypoint while passing `command` args directly. |
| `environment` | array | — | Environment variables as `KEY=VALUE`, passed as `-e`. |
| `volumes` | array | — | Volume mounts as `host:container`, passed as `-v`. Host paths of `.` or beginning with `./` are resolved against `pwd`, so `./src:/app/src` mounts a directory from the checkout. |
| `rm` | boolean | `true` | Remove the run container when the command exits, as `--rm`. Set to `false` to keep the stopped container, named `docker-compose-run-buildkite-plugin-<job id>`, until the `pre-exit` hook removes it, so a `post-command` hook can `docker cp` out of it. Matches the official `docker-compose` plugin's `rm`. |
| `copy-out` | array | — | Paths to copy out of the run container when the command exits, as `<from>:<to>`. A relative `from` is resolved against the container's working directory. `to` is resolved against the job's working directory, and replaced if it exists. See [Copying output out](#copying-output-out). |
| `propagate-aws` | boolean | `false` | Propagate `AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`. |
| `propagate-buildkite-environment` | boolean | `false` | Propagate `CI`, `BUILDKITE` and every `BUILDKITE_*` variable from the agent. |

`additionalProperties` is disabled, so an unrecognised or misspelled option fails validation rather than being silently ignored.

### Commands and shells

The service's command comes from either the step or the plugin, never both:

- **Step command** — `BUILDKITE_COMMAND` is wrapped in `shell` (`/bin/sh -e -c` by default) and passed to `docker compose run`. This is what most steps want, because it supports multi-line scripts, pipes and `&&`.
- **Plugin `command`** — the array is passed as argv. There is no shell unless `shell` names one, in which case the shell is prepended and the array becomes its arguments. Use it for steps that have no command of their own.

Shell wrapping resolves the same way as the official `docker` plugin: off unless something turns it on. A step command turns it on; so does naming a `shell`. An `entrypoint` turns it back off, and an explicit `shell` overrides that in turn.

Setting both `entrypoint` and `shell` composes rather than conflicts, because Docker runs the entrypoint with the container's arguments appended to it. `entrypoint: ""` clears the image's entrypoint so the shell runs directly, and a wrapper entrypoint that execs its arguments — `tini`, `dumb-init`, `env`, `gosu` — runs the shell in turn. An entrypoint that does *not* exec its arguments will instead receive the shell's path as an argument of its own, which is rarely what you want.

If neither is set, the service runs the command from its compose definition.

The plugin fails the step, rather than silently picking one, when the configuration is ambiguous:

- Both a step command and the plugin's `command` are set.
- `command` is given as a string instead of an array.
- `shell` is given as a string instead of an array or `false`.
- `shell` is set as an array while `entrypoint` is also set, since `entrypoint` suppresses shell wrapping.

### Copying output out

Each `copy-out` entry is `<from>:<to>`, source first, like `volumes`:

- **`from`** is a file or directory in the run container. If it is a symlink, what it points to is copied. A relative path is resolved against the working directory the command ran in: the `workdir` option, the service's `working_dir` or the image's `WORKDIR`, and `/` when none of those is set. `docker cp` by itself resolves it against `/`. An absolute path is used as it is.
- **`to`** is a path inside the job's working directory, and relative to it. Its parent directories are created. Whatever is already there is replaced, so `to` ends up holding what `from` holds rather than a copy nested inside it. That includes a service that mounts the checkout over its working directory, where `from` and `to` are the same directory. Because it is replaced, `to` can't be absolute, contain `..`, or be the working directory itself.

The copy runs as soon as the command exits, whether it passed or failed, and before the plugin's `command` hook returns. Every `post-command` hook therefore sees the output, whatever order the agent runs them in.

The step exits with the command's status. A `from` that doesn't exist is logged and skipped, so a command that wrote nothing doesn't fail the step. Any other failure to copy does. An entry that isn't `<from>:<to>`, or whose `to` isn't allowed, fails the step before anything is started.

With `copy-out` the run goes without `--rm`, because the copy needs the stopped container. The plugin removes the container and its anonymous volumes once the copy is done, unless `rm` is `false`, which keeps it until `pre-exit` as usual.

Only the run container can be copied from, not the services it depends on.

## How it works

Everything runs under a compose project named `docker-compose-run-buildkite-plugin-<job id>`, so concurrent jobs on the same agent never collide.

1. **Pull** — `docker compose pull --include-deps <service>` fetches only the target service and its dependency tree. Skipped on older Compose that lacks `--include-deps`.
2. **Up** — `docker compose up --detach --scale <service>=0 <service>` brings up the target's `depends_on` tree without starting the target itself. `--pull never` is added when the pull phase already fetched the images.
3. **Run** — `docker compose run --name docker-compose-run-buildkite-plugin-<job id> --rm <service>` with the configured overrides, again adding `--pull never` when the images are already local. `rm: false` drops `--rm`, so the stopped container outlives the command.
4. **Copy** — only with `copy-out`, which also drops `--rm`: `docker cp` copies each entry out of the stopped run container, then `docker rm --force --volumes` removes it unless `rm` is `false`.
5. **Cleanup** — the `pre-exit` hook writes the project's logs to `docker-compose-run-buildkite-plugin.log`, uploads it as a Buildkite artifact, removes the run container with its anonymous volumes (`docker compose down` removes the container, but leaves those when no `file` is given), then runs `docker compose down --volumes --remove-orphans`.

Each phase is its own log group, so you can fold and expand them independently and see exactly where time is spent.

The up phase does not pass `--wait`, so it starts the dependencies without blocking on their healthchecks: Compose before v2.16.0 hangs forever when `--wait` is combined with `--scale <service>=0`, waiting on the target that is never started ([docker/compose#9149](https://github.com/docker/compose/issues/9149)). Any `depends_on` conditions declared in your compose file are still honoured by the run phase, which is where the target service actually starts.

## Other plugins that may be useful

- [docker-run](https://github.com/jameslnewell/docker-run-buildkite-plugin) — Run a command in a Docker image with phase-level timing and automatic cleanup
- [docker-compose-build](https://github.com/jameslnewell/docker-compose-build-buildkite-plugin) — Build and push a docker compose service using `docker buildx bake`

## Contributing

See [DEVELOPMENT.md](./DEVELOPMENT.md) for how to run the tests and cut a release.
