#!/usr/bin/env bats

setup() {
  load "$BATS_PLUGIN_PATH/load.bash"
  export BUILDKITE_JOB_ID="test-job-id"
  export TMPDIR="$(mktemp -d)"
  cd "$TMPDIR"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "logs collected and artifact uploaded" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml logs --timestamps : echo 'service1_1  | log line 1'; echo 'service2_1  | log line 2'"

  stub buildkite-agent \
    "artifact upload docker-compose-run-plugin.log : true"

  run "$PLUGIN_PATH/hooks/pre-exit"

  assert_success
  assert [ -f "docker-compose-run-plugin.log" ]
  assert_output --partial "Collecting logs"
  assert_output --partial "Cleaning up"

  unstub docker
  unstub buildkite-agent
}

@test "down called with volumes and remove-orphans" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml logs --timestamps : echo ''" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml down --volumes --remove-orphans : true"

  stub buildkite-agent \
    "artifact upload docker-compose-run-plugin.log : true"

  run "$PLUGIN_PATH/hooks/pre-exit"

  assert_success

  unstub docker
  unstub buildkite-agent
}

@test "cleanup runs even if logs command fails" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml logs --timestamps : exit 1" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml down --volumes --remove-orphans : true"

  stub buildkite-agent \
    "artifact upload docker-compose-run-plugin.log : true"

  run "$PLUGIN_PATH/hooks/pre-exit"

  assert_success

  unstub docker
  unstub buildkite-agent
}
