#!/usr/bin/env bats

setup() {
  load "${BATS_LIB_PATH}/bats-support/load.bash"
  load "${BATS_LIB_PATH}/bats-assert/load.bash"
  load "${BATS_LIB_PATH}/bats-mock/stub.bash"

  export PLUGIN_PATH="${BATS_TEST_DIRNAME}/.."
  export BUILDKITE_JOB_ID="test-job-id"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test-service"
}

teardown() {
  unstub docker 2>/dev/null || true
}

@test "script has valid bash syntax" {
  bash -n "$PLUGIN_PATH/hooks/command"
}

@test "missing required service exits with error" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE

  run "$PLUGIN_PATH/hooks/command"

  [[ $status -ne 0 ]]
}

@test "required service is set" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test-service"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; [[ -n \"\$BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE\" ]]"

  [[ $status -eq 0 ]]
}

@test "plugin_read_list returns single string" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE'"

  [[ $status -eq 0 ]]
  [[ "$output" == "docker-compose.yml" ]]
}

@test "plugin_read_list returns array values" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_0="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_1="docker-compose.test.yml"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE'"

  [[ $status -eq 0 ]]
  [[ "$output" == *"docker-compose.yml"* ]]
  [[ "$output" == *"docker-compose.test.yml"* ]]
}

@test "plugin_read_list with indexed array reads all items under set -e" {
  # Regression: (( i++ )) returns exit code 1 when i=0, which set -e in a
  # process substitution subshell would turn into an early exit, silently
  # dropping all items after index 0.
  export MY_VAR_0="first"
  export MY_VAR_1="second"
  export MY_VAR_2="third"
  mapfile -t result < <(set -e; source $PLUGIN_PATH/lib/shared.bash; plugin_read_list "MY_VAR")
  [[ "${#result[@]}" -eq 3 ]]
  [[ "${result[0]}" == "first" ]]
  [[ "${result[1]}" == "second" ]]
  [[ "${result[2]}" == "third" ]]
}

@test "env variable is available in hook environment" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="DATABASE_URL=postgres://localhost"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT'"

  [[ $status -eq 0 ]]
  [[ "$output" == *"DATABASE_URL=postgres://localhost"* ]]
}

@test "volume variable is available in hook environment" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES_0="/host:/container"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES'"

  [[ $status -eq 0 ]]
  [[ "$output" == *"/host:/container"* ]]
}

@test "Runs step command in shell" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --no-deps --pull never --rm test-service /bin/sh -e -c \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Errors when both step and plugin commands are specified" {
  export BUILDKITE_COMMAND="make test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND="npm test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
  assert_output --partial "Error:"
  unset BUILDKITE_COMMAND
}

@test "Starts dependency services before running the target" {
  unset BUILDKITE_COMMAND

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : printf 'dep-service\ntest-service\n'" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id up --wait dep-service : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --no-deps --pull never --rm test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "Plugin command as string errors" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND="node server.js"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
  assert_output --partial "Error:"
}

@test "Empty entrypoint clears image ENTRYPOINT and suppresses shell" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT=""
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service" \
    ":: true"

  run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"

  assert_success
  assert_output --partial "--entrypoint"
  refute_output --partial "/bin/sh -e -c"
  unset BUILDKITE_COMMAND
}

@test "Plugin command array items passed as direct args" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0="node"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_1="server.js"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --no-deps --pull never --rm test-service node server.js : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "Step command with shell false passed directly" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL="false"
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --no-deps --pull never --rm test-service \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Custom shell array wraps step command" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0="/bin/bash"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1="-e"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_2="-c"
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --no-deps --pull never --rm test-service /bin/bash -e -c \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Entrypoint suppresses shell for step commands" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT="/bin/sh"
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --no-deps --pull never --rm --entrypoint /bin/sh test-service \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Shell as string errors" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL="/bin/bash -e -c"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND="npm test"

  stub docker \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id pull : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id config --services : echo test-service"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
  assert_output --partial "Error:"
}
