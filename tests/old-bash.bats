#!/usr/bin/env bats

# Runs the real hooks under the oldest bash the plugin supports, with docker
# stubbed, and checks the argv they emit.
#
# The rest of the suite runs on whatever bash the plugin-tester image ships
# (currently 5.x), where a plain "${arr[@]}" expansion of an empty array is
# perfectly legal — so no test in that suite can catch someone "simplifying" the
# "${arr[@]+"${arr[@]}"}" expansions in the hooks back to the plain form. Only
# running the hooks on an actual old bash catches it, which is what this file does.
#
# It needs a real docker CLI to run the bash images. The plugin-tester image has
# none, so these skip there; CI's full-suite job runs the suite natively on the
# runner, where they do run. Locally, on a host with Docker:
#
#   bats tests/old-bash.bats
#
# The first run pulls the bash images (a few MB each).

setup() {
  load "${BATS_LIB_PATH}/bats-support/load.bash"
  load "${BATS_LIB_PATH}/bats-assert/load.bash"

  # Resolved rather than left as `${BATS_TEST_DIRNAME}/..` because it becomes a
  # docker bind-mount source.
  PLUGIN_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  # The oldest bash the hooks are verified against. macOS still ships 3.2, which
  # is what makes it the floor worth testing rather than an arbitrary old number.
  OLDEST_BASH="3.2"

  STUB_DIR="$(mktemp -d)"

  # Answers the four `--help` probes in hooks/command with no output, so every
  # optional Compose flag reads as unsupported. That is the maximally-empty path:
  # COMPOSE_PROGRESS_ARGS, UP_PRELOADED_ARGS and RUN_PRELOADED_ARGS all stay empty,
  # which is precisely the shape that fails on bash before 4.4.
  cat > "${STUB_DIR}/docker" <<'STUB'
#!/bin/sh
case "$*" in
  "compose --help"|"compose pull --help"|"compose up --help"|"compose run --help")
    exit 0 ;;
esac
echo "DOCKER: $*"
for a in "$@"; do echo "ARG=<$a>"; done
STUB

  cat > "${STUB_DIR}/buildkite-agent" <<'STUB'
#!/bin/sh
echo "AGENT: $*"
STUB

  chmod +x "${STUB_DIR}/docker" "${STUB_DIR}/buildkite-agent"
}

teardown() {
  # An `if` rather than `[[ ... ]] && rm`, which would return non-zero when the
  # variable is unset — and a teardown that returns non-zero fails the test.
  if [[ -n "${STUB_DIR:-}" ]]; then
    rm -rf "${STUB_DIR}"
  fi
}

skip_unless_docker() {
  if ! command -v docker &>/dev/null; then
    skip "needs a real docker CLI; the plugin-tester image has none"
  fi
}

# `docker run` writes pull progress to stderr, and bats merges stderr into $output.
# That progress differs from one image to the next, so on a machine seeing these
# images for the first time it lands inside the argv comparison below and fails it.
# Pull out of band instead — anything run before `run` is not captured.
ensure_image() {
  local image="$1"
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    docker pull --quiet "$image" > /dev/null
  fi
}

# Runs one hook inside `bash:<version>` with docker and buildkite-agent stubbed.
# Extra KEY=VALUE arguments are exported into the container. `redirect` is
# appended to the hook invocation: pass 2>/dev/null to drop the `set -x` trace
# when comparing output between bash versions, since only the argv reaching the
# stub is the thing under test.
run_hook_on_bash() {
  local version="$1" hook="$2" redirect="$3"
  shift 3

  local env_args=()
  local pair
  for pair in "$@"; do
    env_args+=(-e "$pair")
  done

  ensure_image "bash:${version}"

  # The same idiom the hooks use, and for the same reason: this file has to run on
  # the host's bash, which on macOS is 3.2, and env_args is empty in most tests.
  run docker run --rm --workdir /tmp \
    -v "${PLUGIN_DIR}:/plugin:ro" \
    -v "${STUB_DIR}:/stub:ro" \
    -e PATH="/stub:/usr/local/bin:/usr/bin:/bin" \
    -e BUILDKITE_JOB_ID="test-job-id" \
    -e BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test-service" \
    "${env_args[@]+"${env_args[@]}"}" \
    "bash:${version}" \
    bash -c "bash /plugin/hooks/${hook} ${redirect}"
}

@test "command hook emits the bare run argv on the oldest supported bash" {
  skip_unless_docker

  run_hook_on_bash "$OLDEST_BASH" command ""

  assert_success
  refute_output --partial "unbound variable"
  assert_line "DOCKER: compose -p docker-compose-run-buildkite-plugin-test-job-id up --detach --scale test-service=0 test-service"
  assert_line "DOCKER: compose -p docker-compose-run-buildkite-plugin-test-job-id run --rm test-service"
}

@test "command hook emits the bare run argv on bash 4.2" {
  skip_unless_docker

  # The other pre-4.4 version that matters in practice: Amazon Linux 2 and
  # CentOS 7 both ship 4.2, so this is the bash a lot of long-lived agents run.
  run_hook_on_bash "4.2" command ""

  assert_success
  refute_output --partial "unbound variable"
  assert_line "DOCKER: compose -p docker-compose-run-buildkite-plugin-test-job-id run --rm test-service"
}

@test "pre-exit hook does not poison the uploaded log on the oldest supported bash" {
  skip_unless_docker

  # This hook's first expansion sits inside a pipeline, so `set -u` used to kill
  # only that subshell: the hook carried on, the build stayed green, and the
  # "unbound variable" message ended up inside the file uploaded as the service
  # log. Asserting the hook succeeded is not enough — the log content is the
  # symptom, so check it directly.
  run_hook_on_bash "$OLDEST_BASH" pre-exit "; echo '===LOG==='; cat docker-compose-run-buildkite-plugin.log"

  assert_success
  refute_output --partial "unbound variable"
  assert_line "DOCKER: compose -p docker-compose-run-buildkite-plugin-test-job-id down --volumes --remove-orphans"
  assert_line "AGENT: artifact upload docker-compose-run-buildkite-plugin.log"
}

@test "command hook emits identical argv on the oldest supported bash and a modern one" {
  skip_unless_docker

  # Guarding an expansion is only correct if it changes nothing else, so pin that
  # directly: same inputs, two bash versions either side of the 4.4 boundary, and
  # the argv reaching docker has to match byte for byte. The options are chosen to
  # fill every array the hook builds, and the command item deliberately spans
  # several lines — a multi-line item has to survive as one argv entry, which is
  # the property the inner quotes in the idiom preserve.
  local multiline_command="cd /app
echo 'multi
line script'"

  local options=(
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_0=a.yml"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_1=b.yml"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_WORKDIR=/app dir"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0=FOO=bar baz"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES_0=./x:/y"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_PROPAGATE_AWS=true"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0=/bin/sh"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1=-ec"
    "BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0=${multiline_command}"
  )

  # stderr dropped: the `set -x` trace is not argv, and its formatting is allowed
  # to differ between bash versions.
  run_hook_on_bash "$OLDEST_BASH" command "2>/dev/null" "${options[@]}"
  assert_success
  local old_output="$output"

  run_hook_on_bash "5.2" command "2>/dev/null" "${options[@]}"
  assert_success

  assert_equal "$output" "$old_output"
  # Prove the comparison was not vacuous, and that the multi-line item stayed one
  # argument rather than being split into three.
  assert_line "ARG=<--workdir>"
  assert_line "ARG=</app dir>"
  assert_output --partial "ARG=<${multiline_command}>"
}
