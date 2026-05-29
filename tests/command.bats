#!/usr/bin/env bats

setup() {
  load "$BATS_PLUGIN_PATH/load.bash"
  export BUILDKITE_JOB_ID="test-job-id"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test-service"
}

@test "minimal config with service only" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml pull : echo 'pull called'" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml up --wait --scale test-service=0 : echo 'up called'" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml run --no-deps --rm test-service : echo 'run called'"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_output --partial "pull called"
  assert_output --partial "up called"
  assert_output --partial "run called"

  unstub docker
}

@test "file option specified as string" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="custom.yml"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f custom.yml pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f custom.yml up --wait --scale test-service=0 : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f custom.yml run --no-deps --rm test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "array of files" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_0="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_1="docker-compose.test.yml"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml -f docker-compose.test.yml pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml -f docker-compose.test.yml up --wait --scale test-service=0 : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml -f docker-compose.test.yml run --no-deps --rm test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "env option" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENV_0="DATABASE_URL=postgres://localhost"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENV_1="NODE_ENV=test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml up --wait --scale test-service=0 : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml run --no-deps --rm -e DATABASE_URL=postgres://localhost -e NODE_ENV=test test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "volume option" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUME_0="/host/path:/container/path"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml up --wait --scale test-service=0 : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml run --no-deps --rm -v /host/path:/container/path test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "workdir option" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_WORKDIR="/app"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml up --wait --scale test-service=0 : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml run --no-deps --rm --workdir /app test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "entrypoint option" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT="/bin/sh"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml up --wait --scale test-service=0 : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id -f docker-compose.yml run --no-deps --rm --entrypoint /bin/sh test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "missing required service" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
}
