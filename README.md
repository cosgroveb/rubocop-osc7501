# rubocop-osc7501

Report finite direct RuboCop inspections through OSC 7501 terminal status while
preserving ordinary formatter output and exit behavior.

Requires MRI Ruby 2.1 or newer and RuboCop 0.52.0 or newer. The runtime
dependency is RuboCop only.

## Install

```ruby
# Gemfile
gem 'rubocop-osc7501', require: false
```

Run `bundle install`.

## Use

Select the formatter alongside the ordinary formatter you already use:

```sh
bundle exec rubocop --require rubocop/osc7501 \
  --format progress --format RuboCop::OSC7501::Formatter
```

On RuboCop versions with the server, add `--no-server` for the supported
direct-process path:

```sh
bundle exec rubocop --no-server --require rubocop/osc7501 \
  --format progress --format RuboCop::OSC7501::Formatter
```

Selecting only the OSC formatter deliberately requests no ordinary diagnostics.

Equivalent project arguments preserve your formatter selection:

```text
--require rubocop/osc7501
--format progress
--format RuboCop::OSC7501::Formatter
```

`examples/.rubocop` is a RuboCop argument file, not YAML. It contains the
`--require` and formatter arguments above. Copy it beside `.rubocop.yml` when
every invocation from that directory should select both formatters. Do not add
these arguments to a shared configuration when other users do not have the gem.

Requiring `rubocop/osc7501` registers the formatter and installs inert hooks.
Without formatter selection, or with reporting off, an inspection produces no
records.

## Output controls

| Setting | Behavior |
| --- | --- |
| `RUBOCOP_OSC7501=auto` | Default. Report when the selected formatter output is a TTY and `TERM` is not `dumb`. |
| `RUBOCOP_OSC7501=force` | Report even to redirected output or a file. |
| `RUBOCOP_OSC7501=off` | Disable reporting and bypass eager formatter construction. |
| any other value | Raise `ArgumentError` for a selected inspection. |

RuboCop assigns each formatter its own output. Existing `--out` destinations
remain attached to their original formatter. When reporting is enabled and that
output is a File, the adapter writes through its own duplicate so the final
record survives RuboCop closing the original. It closes only that duplicate.

## What is reported

One root record per supported invocation has `app=rubocop`, `title=RuboCop`, no
identity and no numeric progress. The first frame appears before target
discovery and old parallel cache warming. Results use an aggregate message such
as `3/10 file results, 7 reported offenses`. The adapter does not claim a
current filename or recompute RuboCop's failure threshold.

File-result updates are throttled to one per 0.1 seconds on a monotonic clock.
Initial and final records bypass the throttle. Counts reflect delivered
formatter callbacks and their displayed offenses.

Normal return with status 0 reports `done`. A nonzero status reports `error`.
A captured runner abort reports `idle`, so the first Ctrl-C does not appear as a
lint failure. An escaping `Interrupt` or successful `SystemExit` reports
`idle`. An unsuccessful `SystemExit` or other escaping exception reports
`error`. The exception identity and exit status stay unchanged. The formatter's
`finished` callback never publishes a terminal result.

## Boundaries

Supported: finite direct CLI inspections, including autocorrection, fail-level,
fail-fast, parallel runs, multiple formatters, and `--out` files. Help,
version, show-cops, docs/explain, LSP, MCP, initialization, target listing and
automatic configuration generation produce no records. Embedded `Runner` calls
without a CLI invocation are outside scope.

Server, editor and watch sessions are not supported in the first release. Auto
mode naturally stays silent when output is redirected, and force is a detection
override rather than a server claim. The adapter never reopens `/dev/tty`,
installs a signal handler, or adds an `at_exit` hook. A second Ctrl-C using
immediate exit, `SIGKILL`, and other forced termination can leave the last record
in place.

Earlier formatter construction is intentional: the adapter builds the
configured native formatter set before discovery so reporting starts early.
This can open configured output files before a target discovery failure. A
formatter set that returns successfully has its still-open File outputs closed
during cleanup. If construction fails partway, native partial allocations are
left as RuboCop made them, adapter-owned duplicates are closed, and the primary
exception is preserved. The adapter does not reconstruct the native set.

Concurrent independent top-level invocations can overwrite the same terminal
root record, as with the sibling gems. No terminal, display, dismissal or
notification guarantee follows from encoded frames. Live Rex and tmux
acceptance has not been verified.

Reporting also sets the terminal title. While files are inspected, the title
is `rubocop › <current file>`, following the same throttled cadence as progress
messages. The title returns to `rubocop` on completion, failure and stop.

Messages are bounded to 2048 decoded UTF-8 bytes after ANSI, control and
whitespace sanitization. Window titles use the same sanitization and are
capped at 512 bytes including the `rubocop › ` prefix. Terminal formatting is
removed. Writer I/O failures
disable reporting without closing borrowed streams or replacing the command's
result.

## Compatibility

The candidate floor is MRI Ruby 2.1 and RuboCop 0.52.0, derived from
`CLI#execute_runners`, `Runner#aborting?` and the formatter API. No upper bound
is claimed.

Executed acceptance on 2026-11-13:

| Ruby | RuboCop | Result |
| --- | --- | --- |
| 2.1.10 | 0.52.0 | compatibility harness passed |
| 2.1.10 | 0.57.2 | compatibility harness passed |
| 2.6.5 | 1.50.0 | compatibility harness passed |
| 3.4.12 | 1.80.0 | compatibility harness passed |
| 3.4.12 | 1.92.2 | specs and compatibility harness passed |
| 3.4.12 | 0.52.0 | not supported: RuboCop fails before inspection on Psych `safe_load` arity |

Ruby 2.4 with RuboCop 1.0.0 was not available on the implementation machine.
Ruby 3.4 with RuboCop 0.52.0 installs after adding current standard-library
gems, then fails inside RuboCop before inspection with `Psych.safe_load` arity
(`given 5, expected 1`). That pair is not supported. macOS hosted checks and
the remaining CI matrix were not run locally. An unavailable runtime is a
verification limit, not evidence of compatibility. Other Ruby engines are
unverified.

## Development

```sh
bundle install
bundle exec rake
```

The default task runs RuboCop, bundler-audit, actionlint, inline RBS checks,
specs, and installed-gem smoke tests. `bundle exec rspec` runs specs alone.
See [CONTRIBUTING.md](CONTRIBUTING.md) for compatibility lanes, typing and
release setup. Report vulnerabilities through [SECURITY.md](SECURITY.md).
