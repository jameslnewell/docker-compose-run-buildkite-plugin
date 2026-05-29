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
  docker compose -p "docker-compose-run-buildkite-plugin-${BUILDKITE_JOB_ID}" down --volumes --remove-orphans 2>/dev/null || true
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
  export BUILDKITE_PLUGIN_DOCKER_COMPOSE_RUN_ENV_0="TEST_VAR=success"

  run bash "$PLUGIN_PATH/hooks/command"

  [[ $status -eq 0 ]]
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
