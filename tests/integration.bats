#!/usr/bin/env bats

setup() {
  export PLUGIN_PATH="${BATS_TEST_DIRNAME}/.."
  export BUILDKITE_JOB_ID="dcr-test-$$"
  export TEST_TMPDIR="$(mktemp -d)"

  # Create a simple test docker-compose.yml
  cat > "$TEST_TMPDIR/docker-compose.yml" <<'EOF'
version: '3'
services:
  test:
    image: busybox:latest
    command: echo "Service running"
EOF

  cd "$TEST_TMPDIR"
}

teardown() {
  cd /
  rm -rf "$TEST_TMPDIR"
  remove_job "${BUILDKITE_JOB_ID}"
  remove_job "${BUILDKITE_JOB_ID}-a"
  remove_job "${BUILDKITE_JOB_ID}-b"
}

# What pre-exit does, for when a test fails before getting that far.
remove_job() {
  docker rm --force --volumes "docker-compose-run-buildkite-plugin-$1" >/dev/null 2>&1 || true
  docker compose -p "docker-compose-run-buildkite-plugin-$1" down --volumes --remove-orphans 2>/dev/null || true
}

# A dependency for `up` to start, and a service that writes a report and fails,
# the way a test run leaves coverage behind. /scratch is an anonymous volume,
# which `down --volumes` may not remove.
write_report_compose_file() {
  cat > "$TEST_TMPDIR/docker-compose.yml" <<'EOF'
services:
  dep:
    image: busybox:latest
    command: sleep 300
    stop_grace_period: 1s
  test:
    image: busybox:latest
    depends_on: [dep]
    volumes:
      - /scratch
    command: sh -c 'mkdir -p /out && echo "report $${REPORT:-}" > /out/report.txt && exit 3'
EOF
}

# A service that runs in a workspace member's directory and writes its report
# relative to it, the way a monorepo image sets WORKDIR. /scratch is an anonymous
# volume, as above.
write_workspace_compose_file() {
  cat > "$TEST_TMPDIR/docker-compose.yml" <<'EOF'
services:
  dep:
    image: busybox:latest
    command: sleep 300
    stop_grace_period: 1s
  test:
    image: busybox:latest
    depends_on: [dep]
    working_dir: /workdir/backend
    volumes:
      - /scratch
    command: >
      sh -c 'mkdir -p coverage /out
      && echo "report $${REPORT:-}" > coverage/report.txt
      && echo "absolute" > /out/report.txt
      && exit $${EXIT:-0}'
EOF
}

wait_until_running() {
  local waited=0
  until [[ "$(docker container inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; do
    [[ $waited -lt 120 ]] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

skip_if_no_docker() {
  if ! command -v docker &>/dev/null; then
    skip "Docker is not available"
  fi
}

@test "integration: runs service successfully" {
  skip_if_no_docker

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
  [[ "$output" == *"Service running"* ]]
}

@test "integration: respects environment variables" {
  skip_if_no_docker

  # Create docker-compose with env vars
  cat > "$TEST_TMPDIR/docker-compose.yml" <<'EOF'
version: '3'
services:
  test:
    image: busybox:latest
    command: sh -c 'echo $$TEST_VAR'
EOF

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  # ENVIRONMENT, not ENV: the plugin option is `environment`, so the variable this
  # test used to set was one no hook has ever read. It asserted only that the hook
  # exited 0, which it would have done with no variable passed at all.
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="TEST_VAR=success"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
  # The service echoes $TEST_VAR, so the value only appears if it reached the container.
  [[ "$output" == *"success"* ]]
}

@test "integration: respects working directory" {
  skip_if_no_docker

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_WORKDIR="/tmp"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
}

@test "integration: cleans up resources" {
  skip_if_no_docker

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"

  bash "$PLUGIN_PATH/hooks/command" 2>/dev/null || true
  bash "$PLUGIN_PATH/hooks/pre-exit" 2>/dev/null || true

  # Check that the project is cleaned up
  run docker compose -p "docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}" ps --services

  # Should output nothing since project is cleaned up
  [[ "$output" == "" ]] || [[ $status -ne 0 ]]
}

@test "integration: handles missing service" {
  skip_if_no_docker

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="nonexistent"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -ne 0 ]]
}

@test "integration: works with multiple compose files" {
  skip_if_no_docker

  cat > "$TEST_TMPDIR/docker-compose.base.yml" <<'EOF'
version: '3'
services:
  test:
    image: busybox:latest
    command: echo "Multi-file"
EOF

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_0="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE_1="$TEST_TMPDIR/docker-compose.base.yml"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
}

@test "integration: keeps the stopped run container for post-command, until pre-exit removes it and its anonymous volume" {
  skip_if_no_docker
  write_report_compose_file

  # No `file`: Compose finds docker-compose.yml in the working directory. Given
  # the file with `-f`, `down --volumes` removes the anonymous volume itself, so
  # this test could not tell whether pre-exit's own removal ran.
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=kept"
  local container="docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"

  run bash "$PLUGIN_PATH/hooks/command"
  [[ $status -eq 3 ]]

  # What a post-command hook does.
  docker cp "${container}:/out/report.txt" "$TEST_TMPDIR/report.txt"
  [[ "$(cat "$TEST_TMPDIR/report.txt")" == "report kept" ]]

  local volume
  volume="$(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/scratch"}}{{.Name}}{{end}}{{end}}' "$container")"
  [[ -n "$volume" ]]

  bash "$PLUGIN_PATH/hooks/pre-exit"

  run docker container inspect "$container"
  [[ $status -ne 0 ]]
  run docker volume inspect "$volume"
  [[ $status -ne 0 ]]
}

@test "integration: parallel jobs on one daemon keep separate run containers" {
  skip_if_no_docker
  write_report_compose_file

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  local job_a="${BUILDKITE_JOB_ID}-a" job_b="${BUILDKITE_JOB_ID}-b"

  # The shards of a parallel step are separate jobs, so each has its own job id.
  BUILDKITE_JOB_ID="$job_a" BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=a" \
    bash "$PLUGIN_PATH/hooks/command" > "$TEST_TMPDIR/a.log" 2>&1 &
  local pid_a=$!
  BUILDKITE_JOB_ID="$job_b" BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=b" \
    bash "$PLUGIN_PATH/hooks/command" > "$TEST_TMPDIR/b.log" 2>&1 &
  local pid_b=$!
  local status_a=0 status_b=0
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?
  # teardown deletes these, and bats prints a test's output only when it fails
  cat "$TEST_TMPDIR/a.log" "$TEST_TMPDIR/b.log"
  [[ $status_a -eq 3 ]]
  [[ $status_b -eq 3 ]]

  docker cp "docker-compose-run-buildkite-plugin-${job_a}:/out/report.txt" "$TEST_TMPDIR/a.txt"
  docker cp "docker-compose-run-buildkite-plugin-${job_b}:/out/report.txt" "$TEST_TMPDIR/b.txt"
  [[ "$(cat "$TEST_TMPDIR/a.txt")" == "report a" ]]
  [[ "$(cat "$TEST_TMPDIR/b.txt")" == "report b" ]]

  BUILDKITE_JOB_ID="$job_a" bash "$PLUGIN_PATH/hooks/pre-exit"

  run docker container inspect "docker-compose-run-buildkite-plugin-${job_a}"
  [[ $status -ne 0 ]]
  run docker container inspect "docker-compose-run-buildkite-plugin-${job_b}"
  [[ $status -eq 0 ]]

  BUILDKITE_JOB_ID="$job_b" bash "$PLUGIN_PATH/hooks/pre-exit"

  run docker container inspect "docker-compose-run-buildkite-plugin-${job_b}"
  [[ $status -ne 0 ]]
}

@test "integration: copy-out resolves from against the service's working_dir, and leaves the run container to pre-exit" {
  skip_if_no_docker
  write_workspace_compose_file

  # No `file`, so that `down --volumes` would leave the anonymous volume behind
  # (see the kept-container test above) and only pre-exit's removal can clear it.
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=copied"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:backend/coverage"
  local container="docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
  [[ "$(cat backend/coverage/report.txt)" == "report copied" ]]
  [[ ! -e backend/coverage/coverage ]]

  local volume
  volume="$(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/scratch"}}{{.Name}}{{end}}{{end}}' "$container")"
  [[ -n "$volume" ]]

  bash "$PLUGIN_PATH/hooks/pre-exit"

  run docker container inspect "$container"
  [[ $status -ne 0 ]]
  run docker volume inspect "$volume"
  [[ $status -ne 0 ]]
}

@test "integration: copy-out merges what a failing command wrote into an existing to, and keeps its exit status" {
  skip_if_no_docker
  write_workspace_compose_file
  mkdir coverage
  echo earlier > coverage/earlier.txt

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=failed"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_1="EXIT=3"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 3 ]]
  # `docker cp` of the directory itself would have nested it as coverage/coverage.
  [[ "$(ls -A coverage | tr '\n' ' ')" == "earlier.txt report.txt " ]]
  [[ "$(cat coverage/report.txt)" == "report failed" ]]
  [[ "$(cat coverage/earlier.txt)" == "earlier" ]]
}

@test "integration: copy-out skips a from the command never wrote and copies the other entries" {
  skip_if_no_docker
  write_workspace_compose_file

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="docs:docs"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="/out/report.txt:reports/absolute.txt"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
  [[ "$output" == *"Skipped /workdir/backend/docs: not found in the run container"* ]]
  [[ ! -e docs ]]
  [[ "$(cat reports/absolute.txt)" == "absolute" ]]
}

@test "integration: copy-out copies a file to a new path, and into an existing directory under its own name" {
  skip_if_no_docker
  write_workspace_compose_file
  mkdir results
  echo earlier > results/earlier.txt

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="/out/report.txt:reports/nested/absolute.txt"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="/out/report.txt:results"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
  [[ "$(cat reports/nested/absolute.txt)" == "absolute" ]]
  [[ "$(ls -A results | tr '\n' ' ')" == "earlier.txt report.txt " ]]
  [[ "$(cat results/report.txt)" == "absolute" ]]
}

@test "integration: copy-out fails the step when to cannot take the copy, and still copies the next entry" {
  skip_if_no_docker
  write_workspace_compose_file
  # A directory can't be copied over a file.
  echo earlier > coverage

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="/out/report.txt:report.txt"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 1 ]]
  [[ "$output" == *"Error: could not copy /workdir/backend/coverage out of the run container to coverage"* ]]
  [[ "$(cat coverage)" == "earlier" ]]
  [[ "$(cat report.txt)" == "absolute" ]]
}

@test "integration: pre-exit removes the run container of a hook killed mid-command" {
  skip_if_no_docker
  write_workspace_compose_file

  # A cancelled job kills the hook while the command is still running. The
  # service's command is replaced with one that is still running when that
  # happens. No `file`, as above, so `down` alone would leave the volume.
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_0="sleep"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COMMAND_1="300"
  local container="docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"

  bash "$PLUGIN_PATH/hooks/command" > "$TEST_TMPDIR/hook.log" 2>&1 &
  local hook=$!
  # teardown deletes the log, and bats prints a test's output only when it fails
  wait_until_running "$container" || { cat "$TEST_TMPDIR/hook.log"; false; }
  # The hook and the `docker compose run` it is waiting on.
  pkill -KILL -P "$hook"
  kill -KILL "$hook"
  wait "$hook" || true

  local volume
  volume="$(docker container inspect --format '{{range .Mounts}}{{if eq .Destination "/scratch"}}{{.Name}}{{end}}{{end}}' "$container")"
  [[ -n "$volume" ]]

  bash "$PLUGIN_PATH/hooks/pre-exit"

  run docker container inspect "$container"
  [[ $status -ne 0 ]]
  run docker volume inspect "$volume"
  [[ $status -ne 0 ]]
}

@test "integration: copy-out keeps parallel jobs on one daemon apart" {
  skip_if_no_docker
  write_workspace_compose_file

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  local job_a="${BUILDKITE_JOB_ID}-a" job_b="${BUILDKITE_JOB_ID}-b"
  mkdir "$TEST_TMPDIR/a" "$TEST_TMPDIR/b"

  # Each job has its own id and its own working directory on the agent.
  (
    cd "$TEST_TMPDIR/a"
    BUILDKITE_JOB_ID="$job_a" BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=a" \
      bash "$PLUGIN_PATH/hooks/command" > "$TEST_TMPDIR/a.log" 2>&1
  ) &
  local pid_a=$!
  (
    cd "$TEST_TMPDIR/b"
    BUILDKITE_JOB_ID="$job_b" BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENVIRONMENT_0="REPORT=b" \
      bash "$PLUGIN_PATH/hooks/command" > "$TEST_TMPDIR/b.log" 2>&1
  ) &
  local pid_b=$!
  local status_a=0 status_b=0
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?
  # teardown deletes these, and bats prints a test's output only when it fails
  cat "$TEST_TMPDIR/a.log" "$TEST_TMPDIR/b.log"
  [[ $status_a -eq 0 ]]
  [[ $status_b -eq 0 ]]

  [[ "$(cat "$TEST_TMPDIR/a/coverage/report.txt")" == "report a" ]]
  [[ "$(cat "$TEST_TMPDIR/b/coverage/report.txt")" == "report b" ]]
}

@test "integration: copy-out copies what a symlinked from points to, and skips a link that points nowhere" {
  skip_if_no_docker

  # `docker cp` copies a symlink as a symlink unless told to follow it, and a
  # link to /real means nothing on the agent.
  cat > "$TEST_TMPDIR/docker-compose.yml" <<'EOF'
services:
  test:
    image: busybox:latest
    working_dir: /workdir
    command: >
      sh -c 'mkdir -p /real
      && echo "report linked" > /real/report.txt
      && ln -s /real coverage
      && ln -s /real/report.txt latest.txt
      && ln -s /nowhere dangling'
EOF

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_0="coverage:coverage"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_1="latest.txt:latest.txt"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_COPY_OUT_2="dangling:dangling"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
  [[ -d coverage && ! -L coverage ]]
  [[ "$(cat coverage/report.txt)" == "report linked" ]]
  [[ -f latest.txt && ! -L latest.txt ]]
  [[ "$(cat latest.txt)" == "report linked" ]]
  [[ "$output" == *"Skipped /workdir/dangling: not found in the run container"* ]]
  [[ ! -e dangling && ! -L dangling ]]
}
