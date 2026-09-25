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
# which `run --rm` removes and `down --volumes` does not.
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

@test "integration: removes the run container when the command exits by default" {
  skip_if_no_docker
  write_report_compose_file

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 3 ]]
  run docker container inspect "docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}"
  [[ $status -ne 0 ]]
}

@test "integration: rm false keeps the stopped run container for post-command until pre-exit" {
  skip_if_no_docker
  write_report_compose_file

  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_SERVICE="test"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_FILE="$TEST_TMPDIR/docker-compose.yml"
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_RM=false
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
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_RM=false
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
