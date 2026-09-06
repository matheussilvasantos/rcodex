# codex-usage

Displays Codex rate-limit usage using the local `codex app-server`.
Requires Ruby 2.7+ and an installed, authenticated Codex CLI.

```sh
ruby codex-usage.rb
ruby codex-usage.rb --simple  # or -s
ruby codex-usage.rb --json
ruby codex-usage.rb --help
```

Both the bar and percentage show remaining quota. Resets within 24 hours use
relative times; later resets show the local date and time. On terminals, bars and
percentages are green above 30% remaining, yellow above 10% through 30%, and red
at 10% or less. Colors are disabled when output is redirected, `NO_COLOR` is set,
or `TERM=dumb`. JSON output is never colored.

```sh
NO_COLOR=1 ruby codex-usage.rb
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

`--json` prints the unmodified response as pretty-printed JSON and cannot be
combined with `--simple`. Both text modes exit with status 1 when no windows are
returned; CLI and app-server errors also exit with status 1.

## Structure

- `codex-usage.rb`: executable entry point; safe to require without running it.
- `lib/codex_usage/domain.rb`: rate-limit window and usage snapshot value objects.
- `lib/codex_usage/app_server.rb`: subprocess/protocol adapter and mapping from the
  upstream response schema into domain objects.
- `lib/codex_usage/cli.rb`: CLI orchestration and text presentation. Output streams
  and the server factory are injectable.

DDD is limited to a small domain vocabulary and an explicit translation boundary.
There is no persistence or domain lifecycle requiring repositories or aggregates.
The raw JSON path intentionally bypasses domain mapping to retain unknown fields.

## Tests

```sh
ruby -Itest test/codex_usage_test.rb
```

Tests use Minitest and fake Ruby subprocesses; no Codex installation or network
access is needed. Install the `minitest` gem if your Ruby does not bundle it.
