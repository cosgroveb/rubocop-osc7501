# Contributing

Follow the [code of conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through
the private channel in [SECURITY.md](SECURITY.md).

AI-assisted contributions are welcome. Verify claims in code and reports, state
what you tested, and take responsibility for what you submit.

Use MRI Ruby 3.4 or newer for development tooling. Install actionlint 1.7.12 on
your PATH, then run:

```sh
bundle install
bundle exec rake
```

`rake` runs RuboCop with rubocop-rspec, bundler-audit, actionlint, inline RBS
checks, specs, and an isolated installed-gem smoke test. Run `bundle exec rake
lint`, `audit`, `workflows`, `types`, `spec`, `package` or `smoke` separately.
Dependency auditing uses the ignored lockfile from `bundle install`.

Keep runtime dependencies limited to RuboCop. Cover lifecycle behavior with
real subprocesses and fake native boundaries. Specs run in random order and
report their seed. Reproduce an ordering failure with `bundle exec rspec --seed
<seed> --bisect`.

`rake types` checks annotation coverage across authored Ruby files, generates
inline RBS, and uses Steep for implementations in `lib/` and `script/`. Specs
and build configuration receive annotation and signature validation, not
implementation checking. Generated signatures live in ignored `tmp/` during
development and inside the built gem under `sig/`, never in the source tree.
`sig/dependencies.rbs` declares the private RuboCop and RubyGems boundaries that
bundled signatures lack.

The smoke task installs the built gem and RuboCop's dependency closure in a
temporary gem home, then checks clean and offending inspections without loading
companion gems. Modern CI lanes build the canonical package and verify its
generated runtime signatures. The `pure-rubocop` lane builds a source artifact
in isolation to check the runtime-only dependency closure without development
gems.

## Runtime compatibility

The gem targets MRI Ruby 2.1 or newer and RuboCop 0.52.0 or newer. Use
`Gemfile.compat` and `RUBOCOP_VERSION` to select the runtime pair:

```sh
export BUNDLE_GEMFILE=Gemfile.compat
export RUBOCOP_VERSION=0.52.0
bundle install
bundle exec ruby script/compat.rb
```

On Ruby 2.1 install Bundler 1.17.3 first. The compatibility harness checks
done, error and idle outcomes, first Ctrl-C, output and stderr parity, silent
modes, File `--out` finalization and idempotent hooks against the actual
selected executable. It exits nonzero on any failed assertion. Do not treat a
smoke-only lane as full behavior coverage.

Executed pairs are listed in the README. Remove `Gemfile.compat.lock` before
changing RuboCop versions and keep it out of commits. Supporting an older
runtime does not extend its upstream security maintenance.

## Release

Release reviewed commits on remote `main`:

```sh
gh workflow run release.yml --ref main -f version=NEW_VERSION
```

Use a stable `major.minor.patch` version without a `v` prefix. The workflow
captures `main`, updates `VERSION`, builds changelog notes from non-merge
subjects since the previous tag, tests the exact prepared commit, then pushes
the commit and tag atomically. Publication resumes an existing tag instead of
releasing newer commits.

Before the first publication, configure a RubyGems pending Trusted Publisher
for owner `cosgroveb`, repository `rubocop-osc7501`, workflow `release.yml`.
Store a write-enabled repository deploy key as `RELEASE_DEPLOY_KEY`. The publish
job uses OIDC for RubyGems and the workflow token for the GitHub Release.

Update user-visible behavior documentation and write commit subjects that
describe the change, because release notes use them. Do not maintain
`Unreleased` entries by hand.

## Live terminal check

Encoded-frame specs do not prove display or notifications. Check these cases
manually in Rex or tmux against a built gem before making a display claim:

1. Create `sample.rb` with a clean file and `slow_cop.rb` with a slow cop:

   ```ruby
   # frozen_string_literal: true

   module RuboCop
     module Cop
       module Manual
         class Slow < Base
           def on_send(_node)
             200.times { sleep 0.1 }
           end
         end
       end
     end
   end
   ```

2. Run the slow inspection and confirm working status is visible during the
   cop delay, then `done` on exit 0:

   ```sh
   RUBOCOP_OSC7501=force bundle exec rubocop --no-server \
     --require rubocop/osc7501 --require ./slow_cop.rb \
     --format progress --format RuboCop::OSC7501::Formatter sample.rb
   ```

3. Add an offense and repeat without the slow cop. Confirm `error` accompanies
   exit 1 and the ordinary offense output remains readable.
4. Start the slow command again and press Ctrl-C once. Confirm `idle` is shown
   and the process exits nonzero without a second record.
5. Repeat with `RUBOCOP_OSC7501=off` and confirm no status is shown.

Live Rex and tmux acceptance was not run on 2026-11-13. Record the terminal,
tmux and gem versions when someone performs it.
