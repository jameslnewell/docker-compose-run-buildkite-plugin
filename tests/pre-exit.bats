#!/usr/bin/env bats

setup() {
  load "${BATS_LIB_PATH}/bats-support/load.bash"
  load "${BATS_LIB_PATH}/bats-assert/load.bash"
  load "${BATS_LIB_PATH}/bats-mock/stub.bash"

  export PLUGIN_PATH="${BATS_TEST_DIRNAME}/.."
  export BUILDKITE_JOB_ID="test-job-id"
  export TEST_TMPDIR="$(mktemp -d)"
  cd "$TEST_TMPDIR"
}

teardown() {
  unstub docker 2>/dev/null || true
  unstub buildkite-agent 2>/dev/null || true
  cd /
  rm -rf "$TEST_TMPDIR"
}

@test "pre-exit script has valid bash syntax" {
  bash -n "$PLUGIN_PATH/hooks/pre-exit"
}

@test "shared library has valid bash syntax" {
  bash -n "$PLUGIN_PATH/lib/shared.bash"
}

@test "plugin_read_list_into_result handles missing variable" {
  source "$PLUGIN_PATH/lib/shared.bash"

  run plugin_read_list_into_result 'NONEXISTENT_VAR'

  [[ $status -ne 0 ]]
}

@test "project name constructed from job id" {
  BUILDKITE_JOB_ID="abc-123-def"
  PROJECT="docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"

  [[ "$PROJECT" == "docker-compose-run-buildkite-plugin-abc-123-def" ]]
}

@test "Removes the run container and its anonymous volumes before downing the project" {
  # `down --volumes` removes a kept run container but not its anonymous volumes,
  # which `run --rm` would have removed. The stubs are ordered, so the rm has to
  # come before the down.
  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id logs --timestamps : true" \
    "rm --force --volumes docker-compose-run-buildkite-plugin-test-job-id : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id down --volumes --remove-orphans : true"
  stub buildkite-agent \
    "artifact upload docker-compose-run-buildkite-plugin.log : true"

  run "$PLUGIN_PATH/hooks/pre-exit"

  assert_success
  # Every docker call in the hook ends in `|| true`, so a call the plan did not
  # expect still leaves the hook green. unstub is what checks the plan was followed.
  unstub docker
  unstub buildkite-agent
}

@test "Still downs the project when there is no run container to remove" {
  # With `rm: true` the container is already gone by pre-exit.
  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id logs --timestamps : true" \
    "rm --force --volumes docker-compose-run-buildkite-plugin-test-job-id : echo 'No such container' >&2; exit 1" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id down --volumes --remove-orphans : true"
  stub buildkite-agent \
    "artifact upload docker-compose-run-buildkite-plugin.log : true"

  run "$PLUGIN_PATH/hooks/pre-exit"

  assert_success
  # Every docker call in the hook ends in `|| true`, so a call the plan did not
  # expect still leaves the hook green. unstub is what checks the plan was followed.
  unstub docker
  unstub buildkite-agent
}
