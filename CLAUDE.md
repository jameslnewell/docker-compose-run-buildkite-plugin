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

For stubs where an argument contains a newline (e.g. a joined multi-line script),
use `:: true` to accept the call unconditionally and verify via `assert_output --partial`
with stderr captured:

```bash
stub docker \
  "compose ... pull : true" \
  "compose ... up ... : true" \
  ":: true" \       # matches any docker call at this index unconditionally
  ...

run bash -c "${PLUGIN_PATH}/hooks/command 2>&1"
assert_output --partial "/bin/sh -e -c"
```

## shared.bash — use printf not echo

`echo "$value"` swallows values starting with `-e` (bash treats it as a flag).
Always use `printf '%s\n' "$value"` when printing arbitrary variable values.
