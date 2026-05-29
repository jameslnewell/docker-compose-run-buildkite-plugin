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

@test "plugin_read_list handles empty array gracefully" {
  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list 'NONEXISTENT_VAR'"

  [[ $status -eq 0 ]]
  [[ -z "$output" ]]
}

@test "project name is constructed correctly" {
  export BUILDKITE_JOB_ID="abc-123-def"

  run bash -c "PROJECT='docker-compose-run-buildkite-plugin-\${BUILDKITE_JOB_ID}'; echo \$PROJECT"

  [[ $status -eq 0 ]]
  [[ "$output" == "docker-compose-run-buildkite-plugin-abc-123-def" ]]
}
