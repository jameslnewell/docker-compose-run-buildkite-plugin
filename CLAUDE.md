# Docker Compose Run Buildkite Plugin

## Running tests

```bash
docker run --rm -v "$PWD:/plugin:ro" buildkite/plugin-tester
```

## Testing with bats-mock

Stub patterns are parsed via `eval "parsed_patterns=(...)"`, so any argument
containing spaces must be wrapped in escaped quotes so eval treats it as one token:

```bash
# Wrong — eval splits "npm test" into two tokens, won't match the single arg
"compose ... run --no-deps --rm service /bin/sh -e -c npm test : true"

# Correct — eval sees "npm test" as one token
"compose ... run --no-deps --rm service /bin/sh -e -c \"npm test\" : true"
```

Because patterns are eval'd, an argument containing a newline can still be matched
exactly — write it as an ANSI-C quoted string with the `$` escaped so bash passes
`$'...'` through to the stub plan verbatim:

```bash
stub docker \
  "compose ... pull : true" \
  "compose ... run --rm service /bin/sh -ec \$'cd terraform\nterraform init' : true" \
  ...
```

When an exact pattern would be unwieldy, fall back to `:: true` to accept the call
unconditionally and verify via `assert_output --partial` with stderr captured:

```bash
stub docker \
  "compose ... pull : true" \
  "compose ... up ... : true" \
  ":: true" \       # matches any docker call at this index unconditionally
  ...

run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"
assert_output --partial "/bin/sh -e -c"
```

## shared.bash — never round-trip list values through a stream

`plugin_read_list_into_result` appends into the global `result` array. Do not
"simplify" it back into something that prints values for `mapfile -t` to read:
a list item can legitimately contain newlines (a whole script passed as one
`command:` entry), and a newline-delimited round-trip splits it into one argv
entry per line — `sh -c` then runs only the first line and the step still
exits 0.

When a value does have to be printed, use `printf '%s\n' "$value"`, not
`echo "$value"` — `echo` swallows values starting with `-e` (bash treats it as
a flag).

## Array expansions are guarded — don't simplify them back

Both hooks expand arrays that are legitimately empty (`FILE_ARGS` with no `file`,
`RUN_ARGS` with none of workdir/entrypoint/environment/volumes, the
`*_PRELOADED_ARGS` and `COMPOSE_PROGRESS_ARGS` pairs whenever Compose lacks the
flag). Under `set -u`, bash only expands an empty array to nothing from 4.4
onwards; before that it is an `unbound variable` error that kills the hook.

So every array expansion in `hooks/command` and `hooks/pre-exit` is written:

```bash
"${arr[@]+"${arr[@]}"}"
```

not `"${arr[@]}"`. It reads badly and it is meant to stay. Points worth knowing
before changing it:

- It is applied to **every** array expansion, including ones that cannot be empty
  today, so that no later edit has to re-derive which sites are safe. Keep new
  ones consistent with that.
- It does not change argv. The inner quotes keep one element as exactly one word,
  including elements containing spaces or newlines — which matters, because a
  `command` item can be an entire multi-line script.
- `${#arr[@]}` is *not* affected and needs no guard; a count of an unset array is
  0 on every bash.
- The alternative — raising the minimum bash to 4.4 — was considered and rejected.
  It would drop macOS (3.2) and Amazon Linux 2 / CentOS 7 (4.2) agents to buy
  nothing but tidier expansions.

`buildkite/plugin-tester` ships a modern bash, where the plain form works fine, so
the main suite cannot catch a regression here. `tests/old-bash.bats` runs the hooks
under real `bash:3.2` and `bash:4.2` containers; those tests skip when the `docker`
CLI is absent, which includes CI. Run them on a host with Docker.
