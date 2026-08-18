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

@test "xtrace prefix never collides with Buildkite log-group markers" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm test-service /bin/sh -e -c \"make test\" : true"

  # The agent sources this hook, so set -x runs deep enough that the default
  # PS4='+ ' would trace as a run of '+' (e.g. '+++ docker ...') — which
  # Buildkite parses as a log-group header. Source the hook to reproduce that
  # nesting and assert no traced docker command begins with a ---/+++/~~~ marker.
  # Legit headers ("+++ :docker: running") are fine; only flag a marker
  # immediately followed by a traced "docker" command.
  run bash -c "source \"$PLUGIN_PATH/hooks/command\" 2>&1"

  assert_success
  refute_line --regexp '^[-+~]+ docker '
  # Empty PS4 means traced commands start at column 0 with no prefix at all —
  # lock that in so we don't regress to an indented prefix.
  assert_line --regexp '^docker compose'
  unset BUILDKITE_COMMAND
}

@test "Runs step command in shell" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm test-service /bin/sh -e -c \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Skips the pull phase and --pull never when --include-deps or --pull unsupported" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_COMMAND="make test"

  # Older Compose lacks `pull --include-deps`/`run --pull`: the pull phase is skipped
  # entirely and `run` is left to pull on demand (no --pull never). The up phase still
  # starts the dependencies.
  stub docker \
    "compose --help : echo ''" \
    "compose pull --help : echo 'no such flag'" \
    "compose up --help : echo 'no such flag'" \
    "compose run --help : echo 'no such flag'" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id up --detach --scale test-service=0 test-service : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --rm test-service /bin/sh -e -c \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Errors when both step and plugin commands are specified" {
  export BUILDKITE_COMMAND="make test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND="npm test"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
  assert_output --partial "Error:"
  unset BUILDKITE_COMMAND
}

@test "Starts only the run service's dependencies via scale=0" {
  unset BUILDKITE_COMMAND

  # `up --scale test-service=0 test-service` brings up the depends_on tree and waits for
  # their conditions, but scales the target itself to 0 so it is not started here — it
  # runs in the separate `run` phase. Every docker call is stubbed exactly; an unexpected
  # invocation (e.g. starting more than the dependency tree) would fail.
  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  # The dependency tree is started with the target scaled to 0 (not started here).
  assert_output --partial "up --detach --pull never --scale test-service=0 test-service"
}

@test "Plugin command as string errors" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND="node server.js"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true"

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
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
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
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm test-service node server.js : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "Step command with shell false passed directly" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL="false"
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm test-service \"make test\" : true"

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
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm test-service /bin/bash -e -c \"make test\" : true"

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
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm --entrypoint /bin/sh test-service \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Shell array with entrypoint errors" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT="/bin/sh"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0="/bin/bash"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1="-e"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_2="-c"
  export BUILDKITE_COMMAND="make test"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
  assert_output --partial "Error:"
  unset BUILDKITE_COMMAND
}

@test "Shell as string errors" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL="/bin/bash -e -c"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND="npm test"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure
  assert_output --partial "Error:"
}

@test "propagate-aws passes AWS credential and region env vars" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_PROPAGATE_AWS="true"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --rm -e AWS_REGION -e AWS_DEFAULT_REGION -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "propagate-buildkite-environment adds CI and BUILDKITE_* vars" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_PROPAGATE_BUILDKITE_ENVIRONMENT="true"
  export CI="true"
  export BUILDKITE="true"
  export BUILDKITE_BRANCH="main"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    ":: true"

  run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"

  assert_success
  assert_output --partial "-e CI"
  assert_output --partial "-e BUILDKITE "
  assert_output --partial "-e BUILDKITE_BRANCH"
}

@test "propagate-buildkite-environment ignores lines inside a multi-line value" {
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_PROPAGATE_BUILDKITE_ENVIRONMENT="true"
  # A real commit message spans lines; reading `env` line-by-line would take the
  # second line for another NAME=VALUE record and forward BUILDKITE_NOT_A_VAR.
  export BUILDKITE_MESSAGE=$'fix: something\nBUILDKITE_NOT_A_VAR=surprise'

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    ":: true"

  run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"

  assert_success
  assert_output --partial "-e BUILDKITE_MESSAGE"
  refute_output --partial "BUILDKITE_NOT_A_VAR"
}
