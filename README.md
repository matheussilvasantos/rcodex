# rcodex

A Ruby gem for inspecting Codex rate-limit usage via the local `codex app-server`.
Requires Ruby 2.7+ and an installed, authenticated Codex CLI on `PATH`.

## Installation

Build and install from this checkout:

```sh
gem build rcodex.gemspec
gem install ./rcodex-1.0.0.gem
```

This installs the `rcodex` command. Ensure RubyGems' executable directory is on
`PATH`. The gem does not install or authenticate the upstream Codex CLI.
This setup supports local installation; it has not been published to RubyGems.
Before publishing, choose a license and add the project homepage to the gemspec.

## Usage

```sh
rcodex --usage
rcodex --usage --simple  # or --usage -s
rcodex --usage --json
rcodex --help
rcodex --version
```

Running `rcodex` without arguments shows help without starting Codex. Usage
reporting requires `--usage`; `--simple` and `--json` cannot be used alone or
together. This replaces the former `ruby codex-usage.rb` entry point.

Both the bar and percentage show remaining quota. Resets within 24 hours use
relative times; later resets show the local date and time. On terminals, bars and
percentages are green above 30% remaining, yellow above 10% through 30%, and red
at 10% or less. Colors are disabled when output is redirected, `NO_COLOR` is set,
or `TERM=dumb`. JSON output is never colored.

```sh
NO_COLOR=1 rcodex --usage
```

```text
Codex · ChatGPT Plus

5-hour quota   ███████████████░░░░░     75% left
               Resets in 2h 14m

Weekly quota   ██████████████████░░     90% left
               Resets Tue, Sep 9 at 10:00
```

`--simple` (`-s`) prints aligned, sensors-style quota readings without a header,
bars, colors, or reset details, even on terminals:

```text
5-hour quota:   75.0% left
Weekly quota:   90.0% left
```

```sh
watch -n 30 'rcodex --usage --simple'
```

Each refresh starts a new Codex app-server process, so longer polling intervals
are preferable to refreshing every second.

`--json` prints the unmodified response as pretty-printed JSON. Both text modes
exit with status 1 when no windows are returned; CLI and app-server errors also
exit with status 1.

## Development

```sh
bundle install
bundle exec rake test
bundle exec ruby bin/rcodex --usage --simple
```

Alternatively, with Minitest installed, run `ruby -Ilib:test test/rcodex_test.rb`.
Tests use fake Ruby subprocesses; no Codex installation or network access is
needed. `require "rcodex"` loads the library without executing the CLI.

## Structure

- `bin/rcodex`: executable entry point.
- `lib/rcodex.rb`: library entry point under the `RCodex` namespace.
- `lib/rcodex/version.rb`: shared gem and protocol-client version.
- `lib/rcodex/domain.rb`: rate-limit window and usage snapshot value objects.
- `lib/rcodex/app_server.rb`: subprocess/protocol adapter and response mapping.
- `lib/rcodex/cli.rb`: CLI orchestration and text presentation, with injectable
  output streams and server factory.
- `rcodex.gemspec`: gem metadata, packaged files, dependencies, and executable.

DDD is limited to a small domain vocabulary and an explicit translation boundary.
There is no persistence or domain lifecycle requiring repositories or aggregates.
The raw JSON path intentionally bypasses domain mapping to retain unknown fields.
