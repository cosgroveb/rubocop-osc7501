# Accessibility

Read RuboCop output without relying on terminal status indicators. RuboCop keeps
ordinary formatter output and errors available as text.

## Plain text output

Disable status reporting and preselect an ordinary formatter:

```sh
RUBOCOP_OSC7501=off bundle exec rubocop --require rubocop/osc7501 --format progress
```

`RUBOCOP_OSC7501=off` bypasses eager formatter construction. By default RuboCop
sends records only to a TTY with a terminal other than `dumb`.
`RUBOCOP_OSC7501=force` overrides both checks.

## Environments and limits

Terminal status requires an OSC 7501-capable terminal. The gem checks for a TTY
and honors `TERM=dumb` but does not detect OSC support. Your terminal controls
display and announcements. I have not tested status display with screen readers,
and live Rex or tmux presentation has not been verified.

## Report a barrier

Open an [issue](https://github.com/cosgroveb/rubocop-osc7501/issues) describing
what you tried, what prevented you, and what would help. Include terminal,
operating system, and assistive technology versions when relevant. You do not
need to disclose a disability or medical information.
