# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "rbconfig"
require "timeout"
require_relative "../codex-usage"

class CodexUsageTest < Minitest::Test
  class FakeServer
    attr_reader :closed

    def initialize(result: nil, error: nil)
      @result = result
      @error = error
    end

    def rate_limits
      raise @error if @error

      @result
    end

    def close
      @closed = true
    end
  end

  def setup
    @output = StringIO.new
    @error = StringIO.new
  end

  def payload
    {
      "rateLimits" => {
        "planType" => "plus",
        "primary" => { "windowDurationMins" => 300, "usedPercent" => 25 },
        "secondary" => { "windowDurationMins" => 10_080, "usedPercent" => 10 }
      }
    }
  end

  def cli(server)
    CodexUsage::CLI.new(output: @output, error: @error, server_factory: -> { server })
  end

  def test_maps_both_supported_response_shapes
    [payload, { "rateLimitsByLimitId" => { "codex" => payload["rateLimits"] } }].each do |result|
      snapshot = CodexUsage::RateLimitsMapper.call(result)
      assert_equal "plus", snapshot.plan
      assert_equal [300, 10_080], snapshot.windows.map(&:duration_minutes)
      assert_equal [75.0, 90.0], snapshot.windows.map(&:remaining_percent)
      assert snapshot.frozen?
      assert snapshot.windows.frozen?
      assert snapshot.windows.all?(&:frozen?)
    end
  end

  def test_direct_limits_take_precedence_but_plan_can_fall_back
    result = payload
    result["rateLimits"].delete("planType")
    result["rateLimitsByLimitId"] = { "codex" => { "planType" => "pro" } }
    snapshot = CodexUsage::RateLimitsMapper.call(result)
    assert_equal "pro", snapshot.plan
    assert_equal 2, snapshot.windows.size
  end

  def test_missing_windows_and_missing_usage
    assert CodexUsage::RateLimitsMapper.call({}).empty?
    snapshot = CodexUsage::RateLimitsMapper.call("rateLimits" => { "primary" => {} })
    assert_equal 100.0, snapshot.windows.first.remaining_percent
    assert_nil snapshot.windows.first.resets_at
  end

  def test_default_output_and_cleanup
    server = FakeServer.new(result: payload)
    assert_equal 0, cli(server).run([])
    assert_equal <<~OUTPUT, @output.string
      Codex · ChatGPT Plus

      5-hour quota   ███████████████░░░░░     75% left

      Weekly quota   ██████████████████░░     90% left
    OUTPUT
    assert_empty @error.string
    assert server.closed
  end

  def test_simple_output_and_short_option
    ["--simple", "-s"].each do |option|
      @output.truncate(0)
      @output.rewind
      result = payload
      result["rateLimits"]["primary"]["resetsAt"] = Time.now.to_i + 3600
      server = FakeServer.new(result: result)
      assert_equal 0, cli(server).run([option])
      assert_equal <<~OUTPUT, @output.string
        5-hour quota:   75.0% left
        Weekly quota:   90.0% left
      OUTPUT
      assert_empty @error.string
      assert server.closed
    end
  end

  def test_simple_output_is_plain_even_on_a_terminal
    @output.define_singleton_method(:tty?) { true }
    snapshot = CodexUsage::RateLimitsMapper.call(payload)
    CodexUsage::TextRenderer.new(output: @output, env: {}).render(snapshot, simple: true)
    refute_includes @output.string, "\e["
    refute_match(/[█░]/, @output.string)
  end

  def test_simple_output_aligns_generic_labels_and_preserves_fractional_usage
    snapshot = CodexUsage::UsageSnapshot.new(plan: nil, windows: [
      CodexUsage::RateLimitWindow.new(duration_minutes: 15, used_percent: 25.5, resets_at: nil),
      CodexUsage::RateLimitWindow.new(duration_minutes: nil, used_percent: 100, resets_at: nil)
    ])
    CodexUsage::TextRenderer.new(output: @output).render(snapshot, simple: true)
    assert_equal "15-min quota:   74.5% left\nQuota:           0.0% left\n", @output.string
  end

  def test_simple_output_without_windows_reports_error
    server = FakeServer.new(result: {})
    assert_equal 1, cli(server).run(["--simple"])
    assert_empty @output.string
    assert_includes @error.string, "No Codex rate-limit windows were returned."
    assert server.closed
  end

  def test_simple_and_json_are_mutually_exclusive_before_server_startup
    application = CodexUsage::CLI.new(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    [["--simple", "--json"], ["--json", "-s"]].each do |args|
      assert_equal 1, application.run(args)
    end
    assert_empty @output.string
    assert_includes @error.string, "--json and --simple cannot be used together"
  end

  def test_json_preserves_unknown_fields_and_succeeds_without_windows
    result = { "newField" => [1, 2] }
    server = FakeServer.new(result: result)
    assert_equal 0, cli(server).run(["--json"])
    assert_equal result, JSON.parse(@output.string)
    assert_empty @error.string
    assert server.closed
  end

  def test_no_windows_is_an_error_in_text_mode
    server = FakeServer.new(result: {})
    assert_equal 1, cli(server).run([])
    assert_equal "Codex\n\n", @output.string
    assert_equal "No Codex rate-limit windows were returned.\n\n{}\n", @error.string
    assert server.closed
  end

  def test_help_and_invalid_options_do_not_launch_server
    application = CodexUsage::CLI.new(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    assert_equal 0, application.run(["--help"])
    assert_includes @output.string, "Usage: codex-usage [options]"
    assert_equal 1, application.run(["--unknown"])
    assert_includes @error.string, "invalid option"
  end

  def test_failure_reports_error_and_closes_server
    server = FakeServer.new(error: CodexUsage::AppServerError.new("failed"))
    assert_equal 1, cli(server).run([])
    assert_equal "Error: failed\n", @error.string
    assert server.closed
  end

  def test_startup_failure_reports_error
    application = CodexUsage::CLI.new(
      output: @output, error: @error,
      server_factory: -> { raise CodexUsage::AppServerError, "missing executable" }
    )
    assert_equal 1, application.run([])
    assert_equal "Error: missing executable\n", @error.string
  end

  def test_renderer_handles_generic_durations_resets_and_out_of_range_usage
    timestamp = Time.local(2025, 1, 2, 3, 4)
    windows = [
      [2880, -10, timestamp.to_i],
      [120, 110, timestamp.iso8601],
      [15, 50, "invalid timestamp"],
      [nil, 0, nil]
    ].map do |duration, used, reset|
      CodexUsage::RateLimitWindow.new(duration_minutes: duration, used_percent: used, resets_at: reset)
    end
    snapshot = CodexUsage::UsageSnapshot.new(plan: nil, windows: windows)
    CodexUsage::TextRenderer.new(output: @output, clock: -> { timestamp - 172_800 }).render(snapshot)
    assert_includes @output.string, "2-day quota    #{'█' * 20}    110% left"
    assert_includes @output.string, "2-hour quota   #{'░' * 20}    -10% left"
    assert_includes @output.string, "15-min quota"
    assert_equal 2, @output.string.scan("Resets Thu, Jan 2 at 03:04").size
    assert_includes @output.string, "Resets invalid timestamp"
    assert_includes @output.string, "Quota          #{'█' * 20}    100% left"
  end

  def test_terminal_colors_follow_remaining_quota_and_preserve_layout
    { 100 => 32, 30.1 => 32, 30 => 33, 10.1 => 33, 10 => 31, 0 => 31 }.each do |remaining, code|
      snapshot = CodexUsage::UsageSnapshot.new(plan: "plus", windows: [
        CodexUsage::RateLimitWindow.new(
          duration_minutes: 300, used_percent: 100 - remaining, resets_at: nil
        )
      ])
      terminal = StringIO.new
      terminal.define_singleton_method(:tty?) { true }
      plain = StringIO.new
      CodexUsage::TextRenderer.new(output: terminal, env: {}).render(snapshot)
      CodexUsage::TextRenderer.new(output: plain, env: {}).render(snapshot)

      assert_equal 2, terminal.string.scan("\e[#{code}m").size
      assert_equal 2, terminal.string.scan("\e[0m").size
      assert_equal plain.string, terminal.string.gsub(/\e\[\d+m/, "")
      refute_includes plain.string, "\e["
    end
  end

  def test_no_color_and_dumb_terminals_disable_colors
    [{ "NO_COLOR" => "1" }, { "NO_COLOR" => "" }, { "TERM" => "dumb" }].each do |env|
      terminal = StringIO.new
      terminal.define_singleton_method(:tty?) { true }
      snapshot = CodexUsage::RateLimitsMapper.call(payload)
      CodexUsage::TextRenderer.new(output: terminal, env: env).render(snapshot)
      refute_includes terminal.string, "\e["
    end
  end

  def test_json_is_plain_even_on_a_terminal
    @output.define_singleton_method(:tty?) { true }
    assert_equal 0, cli(FakeServer.new(result: payload)).run(["--json"])
    assert_equal payload, JSON.parse(@output.string)
    refute_includes @output.string, "\e["
  end

  def test_reset_times_and_alignment
    now = Time.local(2025, 1, 2, 3, 4)
    {
      -60 => "now",
      0 => "now",
      30 => "in less than a minute",
      60 => "in 1m",
      3600 => "in 1h",
      8040 => "in 2h 14m",
      86_400 => "Fri, Jan 3 at 03:04"
    }.each do |seconds, expected|
      output = StringIO.new
      snapshot = CodexUsage::UsageSnapshot.new(plan: nil, windows: [
        CodexUsage::RateLimitWindow.new(
          duration_minutes: 300, used_percent: 25.5, resets_at: (now + seconds).to_i
        )
      ])
      CodexUsage::TextRenderer.new(output: output, clock: -> { now }).render(snapshot)
      assert_includes output.string, "   74.5% left"
      assert_equal "#{' ' * 15}Resets #{expected}\n", output.string.lines.last
    end
  end
end

class AppServerTest < Minitest::Test
  # A real subprocess exercises framing, handshake order, notifications, and
  # stderr backpressure without requiring an installed or authenticated Codex.
  SERVER = <<~'RUBY'
    require "json"
    $stdout.sync = true
    mode = ARGV.first
    STDERR.write("diagnostic\n" * 20_000) if mode == "noisy"
    initialized = false
    notified = false
    STDIN.each_line do |line|
      message = JSON.parse(line)
      case message["method"]
      when "initialize"
        abort "duplicate initialization" if initialized
        abort "wrong client" unless message.dig("params", "clientInfo", "name") == "codex-usage"
        initialized = true
        puts JSON.generate(id: message["id"], result: {})
      when "initialized"
        notified = true
      when "account/rateLimits/read"
        abort "missing handshake" unless initialized && notified
        if mode == "exit"
          STDERR.puts "server failed"
          exit 1
        end
        puts "diagnostic output"
        puts ""
        puts "null"
        puts "[]"
        puts JSON.generate(method: "notification")
        puts JSON.generate(id: -1, result: {})
        if mode == "error"
          puts JSON.generate(id: message["id"], error: { code: 42, message: "denied" })
        else
          puts JSON.generate(id: message["id"], result: { rateLimits: {} })
        end
      end
    end
  RUBY

  def with_server(mode = "normal")
    server = CodexUsage::AppServer.new(command: [RbConfig.ruby, "-e", SERVER, mode])
    Timeout.timeout(5) { yield server }
  ensure
    server&.close
  end

  def test_handshake_only_happens_once_and_unrelated_messages_are_ignored
    with_server do |server|
      2.times { assert_equal({ "rateLimits" => {} }, server.rate_limits) }
    end
  end

  def test_stderr_is_drained_while_requests_are_processed
    with_server("noisy") do |server|
      assert_equal({ "rateLimits" => {} }, server.rate_limits)
    end
  end

  def test_server_errors
    with_server("error") do |server|
      error = assert_raises(CodexUsage::AppServerError) { server.rate_limits }
      assert_includes error.message, "denied"
      assert_includes error.message, "42"
    end
  end

  def test_unexpected_exit_includes_stderr
    with_server("exit") do |server|
      error = assert_raises(CodexUsage::AppServerError) { server.rate_limits }
      assert_includes error.message, "exited unexpectedly"
      assert_includes error.message, "server failed"
    end
  end

  def test_close_can_be_called_repeatedly
    with_server do |server|
      server.close
      server.close
    end
  end

  def test_missing_executable
    error = assert_raises(CodexUsage::AppServerError) do
      CodexUsage::AppServer.new(command: ["/nonexistent/codex-usage-test"])
    end
    assert_includes error.message, "was not found in PATH"
  end
end
