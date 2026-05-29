#!/usr/bin/env bats

setup() {
  export PLUGIN_PATH="${BATS_TEST_DIRNAME}/.."
  export BUILDKITE_JOB_ID="test-job-id"
}

@test "pre-exit script has valid bash syntax" {
  bash -n "$PLUGIN_PATH/hooks/pre-exit"
}

@test "shared library has valid bash syntax" {
  bash -n "$PLUGIN_PATH/lib/shared.bash"
}

@test "plugin_read_list handles missing variable" {
  source "$PLUGIN_PATH/lib/shared.bash"

  result=$(plugin_read_list 'NONEXISTENT_VAR')

  [[ -z "$result" ]]
}

@test "project name constructed from job id" {
  BUILDKITE_JOB_ID="abc-123-def"
  PROJECT="docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"

  [[ "$PROJECT" == "docker-compose-run-buildkite-plugin-abc-123-def" ]]
}
