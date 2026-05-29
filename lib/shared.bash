#!/usr/bin/env bash

plugin_read_list() {
  local prefix="$1"
  local i=0
  local found=0
  while true; do
    local var="${prefix}_${i}"
    local value="${!var:-}"
    [[ -z "$value" ]] && break
    printf '%s\n' "$value"
    found=1
    (( i++ )) || true  # post-increment evaluates to old value; || true prevents set -e exit when i=0
  done
  if [[ "$found" -eq 0 ]]; then
    local single="${!prefix:-}"
    [[ -n "$single" ]] && printf '%s\n' "$single"
  fi
  return 0
}
