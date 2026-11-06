# Coding conventions

Implementation conventions for SIL, for both human and agent use. Requirements
live in [requirements.md](./requirements.md); parameter specs in
[parameters.md](./parameters.md).

## Layout

| Path                 | Purpose                                             |
| -------------------- | --------------------------------------------------- |
| `sil.sh` (`sil`)     | Entry point; sources libraries via `srcLib`         |
| `src/<name>.sh`      | Function libraries, loaded with `srcLib "<name>"`   |
| `test/<name>.bats`   | Tests for `src/<name>.sh`. `report.sh` is tested in `manifest.bats`, as it only serves manifests; `fetch.bats` covers what `ingest.bats` can't test with real downloads |
| `test/test_helper.bash` | Shared test setup (`load test_helper`)           |
| `templates/`         | Files copied when creating a new library            |
| `.shellcheckrc`      | Lint settings for `make lint`                       |

## Naming

* Functions: `camelCase`, declared as `function name {`
* Parameters: global `SIL_<NAME>` (uppercase), set only by `src/params.sh`
* Internal globals: `_sil` prefix (`_silArgs`, `_silParamType`). Never use the
  `SIL_` prefix for anything that is not a parameter
* Function variables: always `local`

## Bash gotchas

* `srcLib` sources files from *inside a function*. Any `declare` at file level
  in `src/` must use `-g` (`declare -gA`, `declare -ga`) or it will vanish when
  `srcLib` returns
* Set variables by name with `printf -v "$name" '%s' "$value"`. Never `eval`
  values from manifests or conf files
* bats runs tests under `set -e`: `(( x++ ))` fails when `x` is 0. Use
  `x=$(( x + 1 ))`
* `msgError` inside `$(...)` only exits that subshell, not SIL. A function that
  may halt should return its result through a caller-named variable
  (`printf -v "$resultVar"`, see `shrinkImage`) rather than STDOUT
* A function returning through a caller-named variable must prefix its own
  locals with `_` (`local _hash`). Otherwise a caller choosing the same name
  (`storeImage file hash`) gets the function's local set, not its own
* `BASH_REMATCH` is overwritten by every `=~` match, including inside called
  functions. Copy captures to a local straight after the match
* Read files with `while IFS= read -r line || [[ -n "$line" ]]` to keep
  backslashes and the final unterminated line

## Messaging (UI-01, UI-02)

Use the `msg*` functions in `src/utils.sh`, never bare `echo` for user
messages. All messages go to STDERR. The exception is `showHelp`, which writes
plain text to STDOUT, as help is the requested result.

| Function   | Use                                     |
| ---------- | --------------------------------------- |
| `msgInfo`  | Progress / information (blue)           |
| `msgWarn`  | Problem, execution continues (red)      |
| `msgError` | Fatal; prints and exits with status 1 (red on yellow) |
| `msgDebug` | Developer debugging                     |
| `msg`      | Base function: `msg <ansi codes> <text>` |

Name new functions so they can't be confused with system commands or builtins
(`info`, `error`, `warn` etc). Check with `type -t <name>` - it should print
nothing.

Messages start with a marker: `[!]` problem, `[?]` unclear input. When the user
must act, show the command to run and what SIL can't do without it.

## Adding a parameter

Every new parameter needs all of the following, in the same change:

1. `src/params.sh`: an entry in `_silParamType`, plus `_silParamAlias` and
   `_silParamDefault` entries if it has aliases or a default
2. `docs/parameters.md`: a section giving aliases, type, default and behavior
3. `templates/sil.conf`: a commented-out example with commentary, following
   the existing entries:
   * Comment lines first, written for end users rather than developers:
     what it does, when you would change it, the default, and any tool to
     install
   * A blank line, then the example as `# PARAM=value` with a realistic value
   * A blank line before the next entry
   * Only include settings that could reasonably apply to the whole library
     (eg `SHRINK`, `THRESHOLD`). Leave out parameters applied to individual
     images (`TAG`), one-time actions (`LINK`) and ones that make no sense
     inside a library's own config (`LIBRARY`). Note why in the parameter's
     `parameters.md` section, and give it an entry in `_silParamScope` in
     `src/params.sh` (`image`, `action` or `global`). SIL then warns and
     ignores it in conf files, and the template test skips it
4. `test/params.bats`: tests for any new type, alias or default
5. `src/help.sh` and the parameter table in `README.md`: a line and a row, with
   any aliases. `test/help.bats` fails if either is missing

## Comments and licensing

* Use `#` comments only, including for multi-line blocks (no heredoc or
  string-variable tricks)
* No license text in source files; the MIT `LICENSE` file covers the repo

## Function documentation

Google Shell Style Guide header, omitting sections that don't apply:

```bash
#######################################
# One-line functional role.
# Globals:
#   Variables read or set
# Arguments:
#   $1 - Meaning
# Outputs:
#   What is written to STDOUT/STDERR
# Returns:
#   Status meaning; note if the function can halt (msgError)
#######################################
```

## Testing

* Run `make test` and `make lint` before considering work done; both must pass
* Prefer fixing a lint warning over silencing it. When silencing is right, use
  an inline `# shellcheck disable=SCxxxx` with a reason, not `.shellcheckrc`
* Every `src/` function with logic gets a test in `test/<name>.bats`
* Test setup: `load test_helper`, `setup_sandbox` (which also points `HOME` into
  the sandbox), set `myDir="$PROJECT_ROOT"`, then
  `source "$PROJECT_ROOT/src/utils.sh"` and `srcLib` what's needed
* Tests make no network requests. Use the local web server in `ingest.bats`, a
  stand-in function (see `fetch.bats`), or `http://127.0.0.1:1/` for a connection
  that is refused at once
* `make test-spaces` runs the whole suite under a folder with a space in its
  name. Run it after changing how paths reach external tools
* Use `run` to test failures and `msgError`, since `msgError` exits the shell
