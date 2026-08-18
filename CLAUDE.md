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
