#!/usr/bin/env bash

# Reads a plugin array option into the global `result` array, returning non-zero
# when the option is unset so callers can branch on it. Named after (and behaving
# like) plugin_read_list_into_result in the official buildkite docker plugin.
#
# Items are appended to the array rather than printed and re-read line by line.
# A list item may legitimately contain newlines — `command: ["/bin/sh", "-ec", <script>]`
# passes an entire shell script as a single item — and any newline-delimited
# round-trip (`printf '%s\n'` piped into `mapfile -t`) turns such an item into one
# argv entry per line. That failure is silent and green: `sh -c` runs the first
# line as the script and binds the remaining lines to $0, $1, … so a step whose
# script is `cd <dir>` followed by real work only ever runs the `cd`, which
# succeeds.
plugin_read_list_into_result() {
  local prefix="$1"
  local i=0
  result=()
  while true; do
    local var="${prefix}_${i}"
    local value="${!var:-}"
    [[ -z "$value" ]] && break
    result+=("$value")
    # i=$((...)) rather than (( i++ )): the latter evaluates to 0 when i=0, which
    # set -e reads as a failure and would drop every item after index 0.
    i=$((i + 1))
  done
  # The agent exports the unindexed variable when the option was given as a
  # scalar rather than a YAML array — `file` is documented as accepting either.
  if [[ ${#result[@]} -eq 0 && -n "${!prefix:-}" ]]; then
    result+=("${!prefix}")
  fi
  [[ ${#result[@]} -gt 0 ]]
}
