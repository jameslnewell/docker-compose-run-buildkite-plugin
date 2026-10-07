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

@test "plugin_read_list_into_result returns single string" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="docker-compose.yml"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list_into_result 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE'; printf '%s\n' \"\${result[@]}\""

  [[ $status -eq 0 ]]
  [[ "$output" == "docker-compose.yml" ]]
}

@test "plugin_read_list_into_result returns array values" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_0="docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_1="docker-compose.test.yml"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list_into_result 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE'; printf '%s\n' \"\${result[@]}\""

  [[ $status -eq 0 ]]
  [[ "$output" == *"docker-compose.yml"* ]]
  [[ "$output" == *"docker-compose.test.yml"* ]]
}

@test "plugin_read_list_into_result with indexed array reads all items under set -e" {
  # Regression: (( i++ )) returns exit code 1 when i=0, which set -e would turn
  # into an early return, silently dropping all items after index 0.
  export MY_VAR_0="first"
  export MY_VAR_1="second"
  export MY_VAR_2="third"
  run bash -c "set -e; source $PLUGIN_PATH/lib/shared.bash; plugin_read_list_into_result 'MY_VAR'; printf '%s\n' \"\${#result[@]}\""
  [[ $status -eq 0 ]]
  [[ "$output" == "3" ]]
}

@test "plugin_read_list_into_result keeps a multi-line item as one entry" {
  # Regression: the list used to be printed newline-delimited and re-read with
  # mapfile -t, which split a multi-line item into one entry per line.
  export MY_VAR_0="/bin/sh"
  export MY_VAR_1="-ec"
  export MY_VAR_2=$'cd terraform\nterraform init'
  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list_into_result 'MY_VAR'; printf '%s\n' \"\${#result[@]}\""
  [[ $status -eq 0 ]]
  [[ "$output" == "3" ]]
}

@test "env variable is available in hook environment" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="DATABASE_URL=postgres://localhost"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list_into_result 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT'; printf '%s\n' \"\${result[@]}\""

  [[ $status -eq 0 ]]
  [[ "$output" == *"DATABASE_URL=postgres://localhost"* ]]
}

@test "volume variable is available in hook environment" {
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES_0="/host:/container"

  run bash -c "source $PLUGIN_PATH/lib/shared.bash; plugin_read_list_into_result 'BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_VOLUMES'; printf '%s\n' \"\${result[@]}\""

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service /bin/sh -e -c \"make test\" : true"

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service /bin/sh -e -c \"make test\" : true"

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
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --name docker-compose-run-buildkite-plugin-test-job-id test-service /bin/sh -e -c \"make test\" : true"

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service : true"

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service node server.js : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "Multi-line plugin command item stays a single arg" {
  # Regression: a `command:` item holding a whole shell script used to be split
  # into one argv entry per line, so `sh -c` ran only the first line (typically
  # a `cd`) and bound the rest to $0, $1, … — silently, and with exit status 0.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0="/bin/sh"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_1="-ec"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_2=$'cd terraform\nterraform init'

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service /bin/sh -ec \$'cd terraform\nterraform init' : true"

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service \"make test\" : true"

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service /bin/bash -e -c \"make test\" : true"

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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id --entrypoint /bin/sh test-service \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Explicit shell array applies alongside a cleared entrypoint" {
  # An entrypoint suppresses the *default* shell, but naming one explicitly turns
  # wrapping back on — the official docker plugin resolves the two in that order.
  # Clearing the service's entrypoint and then asking for a shell is the common
  # reason to set both.
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT=""
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0="/bin/bash"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1="-e"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_2="-c"
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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id --entrypoint \"\" test-service /bin/bash -e -c \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Explicit shell array applies alongside a wrapper entrypoint" {
  # Compose concatenates entrypoint and command, so a wrapper entrypoint that
  # execs its arguments (tini, dumb-init, env, gosu) composes with a shell. This
  # combination used to fail the step outright.
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENTRYPOINT="/usr/bin/env"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0="/bin/bash"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1="-e"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_2="-c"
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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id --entrypoint /usr/bin/env test-service /bin/bash -e -c \"make test\" : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unset BUILDKITE_COMMAND
}

@test "Explicit shell array wraps the plugin command" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0="/bin/sh"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1="-e"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_2="-c"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0=$'cd terraform\nterraform init'

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service /bin/sh -e -c \$'cd terraform\nterraform init' : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "Plugin command without a shell stays bare argv" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0="npx"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_1="prisma"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service npx prisma : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
}

@test "Explicit shell is not added when there is no command to run" {
  # A shell with no script operand exits with "-c requires an argument", so the
  # shell must never be prepended with nothing to wrap — the service's own
  # command is what should run. The official plugin emits the bare shell here.
  unset BUILDKITE_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_0="/bin/sh"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_1="-e"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SHELL_2="-c"

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service : true"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
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
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id -e AWS_REGION -e AWS_DEFAULT_REGION -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN test-service : true"

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

@test "Emits the bare run argv when no optional config is set" {
  # Every array the hook expands is empty here: no file, no workdir, entrypoint,
  # environment or volumes, no step or plugin command, and a compose that advertises
  # none of the optional flags. That is the shape the guarded array expansions exist
  # for. This suite runs on a modern bash, where the plain expansions would pass too,
  # so this test pins the argv rather than the bash floor — tests/old-bash.bats runs
  # the same path on bash 3.2. Every docker call is stubbed exactly, so a stray
  # argument fails the test.
  unset BUILDKITE_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0

  stub docker \
    "compose --help : echo ''" \
    "compose pull --help : echo 'no such flag'" \
    "compose up --help : echo 'no such flag'" \
    "compose run --help : echo 'no such flag'" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id up --detach --scale test-service=0 test-service : true" \
    "compose -p docker-compose-run-buildkite-plugin-test-job-id run --name docker-compose-run-buildkite-plugin-test-job-id test-service : true"

  run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"

  assert_success
  assert_line "docker compose -p docker-compose-run-buildkite-plugin-test-job-id run --name docker-compose-run-buildkite-plugin-test-job-id test-service"
}

@test "Always names the run container and never passes --rm" {
  # copy-out and post-command hooks read from the stopped container, which
  # pre-exit removes by this name. `rm` is no longer an option, and a value left
  # in a step's config changes nothing. Without --rm, compose run still exits
  # with the service's status.
  unset BUILDKITE_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND
  unset BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_RM=true

  stub docker \
    "compose --help : printf '  --progress plain\n'" \
    "compose pull --help : printf '  --include-deps\n'" \
    "compose up --help : printf '  --pull\n'" \
    "compose run --help : printf '  --pull\n'" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id pull --include-deps test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id up --detach --pull never --scale test-service=0 test-service : true" \
    "compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service : exit 3"

  run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"

  assert_failure 3
  assert_line "docker compose --progress=plain -p docker-compose-run-buildkite-plugin-test-job-id run --pull never --name docker-compose-run-buildkite-plugin-test-job-id test-service"
  refute_output --partial -- "--rm"
  unstub docker
}

# copy-out writes into the job's working directory, and the checkout these tests
# start in is mounted read-only inside plugin-tester.
enter_job_directory() {
  mkdir -p "$BATS_TEST_TMPDIR/job"
  cd "$BATS_TEST_TMPDIR/job"
}

# The compose project and the run container share a name.
JOB="docker-compose-run-buildkite-plugin-test-job-id"

# Stubs docker up to the end of the run, for a Compose with none of the optional
# flags, and then for the calls given. $1 is what the run does.
stub_docker_through_run() {
  local run="$1"
  shift
  stub docker \
    "compose --help : echo ''" \
    "compose pull --help : echo 'no such flag'" \
    "compose up --help : echo 'no such flag'" \
    "compose run --help : echo 'no such flag'" \
    "compose -p ${JOB} up --detach --scale test-service=0 test-service : true" \
    "compose -p ${JOB} run --name ${JOB} test-service : ${run}" \
    "$@"
}

@test "copy-out copies a directory's contents to a to that does not exist, after the run" {
  # A relative `from` is resolved against the run container's working directory;
  # `docker cp` alone would resolve it against /. `/.` asks for the directory's
  # contents, and the probe before it is what says `from` is a directory. The
  # stubs are ordered, so the copy has to come after the run and nothing may
  # follow it. The copy's stub fails unless backend/ has been created.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:backend/coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /workdir/backend" \
    "cp --follow-link ${JOB}:/workdir/backend/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/workdir/backend/coverage/. backend/coverage : mkdir \"\$4\" && echo copied > \"\$4/report.txt\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_line -- "--- :docker: copying out"
  assert_line "Copied /workdir/backend/coverage to backend/coverage"
  assert_equal "$(cat backend/coverage/report.txt)" "copied"
  unstub docker
}

@test "copy-out copies a directory's contents into a to that exists, and keeps what was there" {
  # Asked for the directory itself, `docker cp` would put it inside `to`, as
  # coverage/coverage. What is already in `to` is the consumer's to clear.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory
  mkdir coverage
  echo earlier > coverage/earlier.txt

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. coverage : echo copied > \"\$4/report.txt\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_equal "$(ls -A coverage | tr '\n' ' ')" "earlier.txt report.txt "
  assert_equal "$(cat coverage/earlier.txt)" "earlier"
  unstub docker
}

@test "copy-out copies a file to a path that does not exist" {
  # Only a directory has contents to ask for, so the first probe comes back
  # empty and the second says the path is there. The copy's stub fails unless
  # test-results/ has been created.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="/out/junit.xml:test-results/junit.xml"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/out/junit.xml/. - : echo 'not a directory' >&2; exit 1" \
    "cp --follow-link ${JOB}:/out/junit.xml - : echo tar" \
    "cp --follow-link ${JOB}:/out/junit.xml test-results/junit.xml : echo results > \"\$4\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  refute_output --partial "not a directory"
  assert_line "Copied /out/junit.xml to test-results/junit.xml"
  assert_equal "$(cat test-results/junit.xml)" "results"
  unstub docker
}

@test "copy-out copies a file into a to that is a directory" {
  # As `cp` does: the file goes in under its own name.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="/out/junit.xml:test-results"
  enter_job_directory
  mkdir test-results
  echo earlier > test-results/earlier.xml

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/out/junit.xml/. - : exit 1" \
    "cp --follow-link ${JOB}:/out/junit.xml - : echo tar" \
    "cp --follow-link ${JOB}:/out/junit.xml test-results : echo results > \"\$4/junit.xml\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_equal "$(ls -A test-results | tr '\n' ' ')" "earlier.xml junit.xml "
  unstub docker
}

@test "copy-out still copies when the command fails, and keeps its exit status" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "exit 3" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. coverage : mkdir \"\$4\" && echo copied > \"\$4/report.txt\""

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 3
  assert_equal "$(cat coverage/report.txt)" "copied"
  unstub docker
}

@test "copy-out resolves a relative from against / when the container has no working directory" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo ''" \
    "cp --follow-link ${JOB}:/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/coverage/. coverage : mkdir \"\$4\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "copy-out uses an absolute from as it is" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="/var/reports:reports"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/var/reports/. - : echo tar" \
    "cp --follow-link ${JOB}:/var/reports/. reports : mkdir \"\$4\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  unstub docker
}

@test "copy-out strips a leading ./ from from, and hands to to docker cp as written" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="./coverage:./backend/coverage/"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. ./backend/coverage/ : mkdir \"\$4\" && echo copied > \"\$4/report.txt\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_line "Copied /app/coverage to ./backend/coverage/"
  assert_equal "$(cat backend/coverage/report.txt)" "copied"
  unstub docker
}

@test "copy-out copies a directory's contents into the job's working directory when to is ." {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="dist:."
  enter_job_directory
  echo earlier > package.json

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/dist/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/dist/. . : echo built > \"\$4/app.js\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_line "Copied /app/dist to ."
  assert_equal "$(ls -A | tr '\n' ' ')" "app.js package.json "
  unstub docker
}

@test "copy-out copies to a to outside the job's working directory" {
  # Nothing at `to` is removed any more, so it no longer has to stay inside.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:${BATS_TEST_TMPDIR}/absolute/coverage"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="docs:../relative/docs"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. ${BATS_TEST_TMPDIR}/absolute/coverage : mkdir \"\$4\" && echo copied > \"\$4/report.txt\"" \
    "cp --follow-link ${JOB}:/app/docs/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/docs/. ../relative/docs : mkdir \"\$4\" && echo copied > \"\$4/index.html\""

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_equal "$(cat "$BATS_TEST_TMPDIR/absolute/coverage/report.txt")" "copied"
  assert_equal "$(cat "$BATS_TEST_TMPDIR/relative/docs/index.html")" "copied"
  unstub docker
}

@test "copy-out skips a from that does not exist" {
  # Asking for a missing path as a tar stream writes nothing to stdout, which is
  # how the hook tells it apart from a copy that failed. Nothing arrives from a
  # container that has gone either, so the hook asks for / as well, which is
  # always there.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo 'Could not find the file' >&2; exit 1" \
    "cp --follow-link ${JOB}:/app/coverage - : echo 'Could not find the file' >&2; exit 1" \
    "cp ${JOB}:/ - : echo tar"

  run "$PLUGIN_PATH/hooks/command"

  assert_success
  assert_line "Skipped /app/coverage: not found in the run container"
  refute_output --partial "Could not find the file"
  [[ ! -e coverage ]]
  unstub docker
}

@test "copy-out does not take a container it cannot read for a from that does not exist" {
  # The tar stream is just as empty when the container has gone, the daemon has
  # stopped answering, or the container's filesystem can't be mounted. Then /
  # comes back empty too. That is a failed copy, and docker's own error says why.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : exit 1" \
    "cp --follow-link ${JOB}:/app/coverage - : exit 1" \
    "cp ${JOB}:/ - : exit 1" \
    "cp --follow-link ${JOB}:/app/coverage coverage : echo 'No such container' >&2; exit 1"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 1
  refute_output --partial "Skipped"
  assert_output --partial "No such container"
  assert_line "Error: could not copy /app/coverage out of the run container to coverage"
  unstub docker
}

@test "copy-out fails the hook when a copy fails" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. coverage : echo 'no space left on device' >&2; exit 1"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 1
  assert_output --partial "no space left on device"
  assert_line "^^^ +++"
  assert_line "Error: could not copy /app/coverage out of the run container to coverage"
  unstub docker
}

@test "copy-out keeps the command's exit status when a copy fails too" {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "exit 3" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. coverage : echo 'no space left on device' >&2; exit 1"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 3
  unstub docker
}

@test "copy-out fails an entry whose to has nowhere to go, and carries on" {
  # reports is a file, so reports/ can't be created for the copy to go in. That
  # must not end the hook on the spot with mkdir's status: the next entry is
  # still copied, and the command's status is still the one the hook exits with.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:reports/coverage"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="docs:docs"
  enter_job_directory
  echo earlier > reports

  stub_docker_through_run "exit 3" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/docs/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/docs/. docs : mkdir \"\$4\" && echo copied > \"\$4/index.html\""

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 3
  assert_line "Error: could not copy /app/coverage out of the run container to reports/coverage"
  assert_equal "$(cat reports)" "earlier"
  assert_equal "$(cat docs/index.html)" "copied"
  unstub docker
}

@test "copy-out attempts every entry after one fails" {
  # One that fails, one that is missing and one that is copied, in that order.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="dist:dist"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="docs:docs"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_2="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo /app" \
    "cp --follow-link ${JOB}:/app/dist/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/dist/. dist : echo 'no space left on device' >&2; exit 1" \
    "cp --follow-link ${JOB}:/app/docs/. - : exit 1" \
    "cp --follow-link ${JOB}:/app/docs - : exit 1" \
    "cp ${JOB}:/ - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. - : echo tar" \
    "cp --follow-link ${JOB}:/app/coverage/. coverage : mkdir \"\$4\" && echo copied > \"\$4/report.txt\""

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 1
  assert_line "Error: could not copy /app/dist out of the run container to dist"
  assert_line "Skipped /app/docs: not found in the run container"
  assert_line "Copied /app/coverage to coverage"
  assert_equal "$(ls -A)" "coverage"
  unstub docker
}

@test "copy-out keeps the command's exit status when the run left no container" {
  # A run that fails before creating its container, such as one naming a service
  # the compose file doesn't have, leaves nothing to copy out of.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "exit 2" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo 'No such container' >&2; exit 1"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 2
  unstub docker
}

@test "copy-out fails the hook when a command that passed left no container" {
  # Nothing was copied, so the step must not pass as though it had been.
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  enter_job_directory

  stub_docker_through_run "true" \
    "container inspect --format '{{.Config.WorkingDir}}' ${JOB} : echo 'No such container' >&2; exit 1"

  run "$PLUGIN_PATH/hooks/command"

  assert_failure 1
  assert_line "Error: there is no run container to copy out of"
  unstub docker
}

# A copy-out entry the hook must refuse before it calls docker at all, so no
# container exists yet. The hook's first docker calls are `--help` probes piped
# into `grep -q`, which print nothing either way, so the docker on PATH here
# records that it was called.
assert_copy_out_rejected() {
  unset BUILDKITE_COMMAND
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="$1"
  enter_job_directory
  mkdir "$BATS_TEST_TMPDIR/shims"
  printf '#!/bin/sh\ntouch "%s"\n' "$BATS_TEST_TMPDIR/docker-called" > "$BATS_TEST_TMPDIR/shims/docker"
  chmod +x "$BATS_TEST_TMPDIR/shims/docker"

  run env PATH="$BATS_TEST_TMPDIR/shims:$PATH" "$PLUGIN_PATH/hooks/command"

  assert_failure 1
  assert_line --index 0 "+++ Error: Each copy-out entry must be \"<from>:<to>\", a path in the container and a path in the job's working directory. Got \"$1\"."
  [[ ! -e "$BATS_TEST_TMPDIR/docker-called" ]]
}

@test "copy-out rejects an entry with no colon" {
  assert_copy_out_rejected "coverage"
}

@test "copy-out rejects an entry with more than one colon" {
  assert_copy_out_rejected "tests:coverage:coverage"
}

@test "copy-out rejects an entry with an empty from" {
  assert_copy_out_rejected ":coverage"
}

@test "copy-out rejects an entry with an empty to" {
  assert_copy_out_rejected "coverage:"
}
