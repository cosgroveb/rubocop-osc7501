# Project guide

`rubocop-osc7501` is an opt-in OSC 7501 reporter for RuboCop inspections.
Target MRI Ruby >= 2.1 and RuboCop >= 0.52.0. Runtime dependencies stay limited
to RuboCop.

- `lib/rubocop/osc7501.rb` registers the formatter and installs inert hooks.
- `lib/rubocop/osc7501/` holds the formatter, lifecycle election and writer.
- `spec/rubocop/` covers runtime behavior and real subprocesses.
- `script/release.rb` uses modern Ruby only.

Run `bundle install`, then `bundle exec rake` for quality checks, specs and
RDoc. Compatibility jobs use `Gemfile.compat`.

Preserve RuboCop's inspection output, autocorrect streams, exceptions and exit
status. Keep records bounded and sanitize text. Do not add process-wide exit
hooks, signal handlers, terminal queries or worker aggregation.

Pre-1.0, no API-stability promise. Two interfaces: the Ruby API
(formatter registration and preserved RuboCop behavior) and the emitted escape
sequences, which consumers parse. OSC 7501 frames must keep conforming.
Patch for fixes, minor for new behavior including added sequences;
removing or changing sequences is breaking.

Release with `script/release.rb prepare <version> <dir>`, build the gem,
then `publish <dir> <gem>`: the script handles the tag, the atomic main+tag
push, the RubyGems push and the GitHub release, then verifies the published
gem. If a release fails, inspect the logs and rerun the same version to
finish missing steps.

All authored Ruby files and methods require inline RBS without blanket untyped
annotations. Keep type tools in modern development bundles. Do not commit
gems, HTML, lockfiles, bundle state or generated signatures. Preserve LICENSE
verbatim. Agent plans and designs belong in GBrain, never Git.
