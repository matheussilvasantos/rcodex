# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "rbconfig"
require "timeout"
require_relative "../lib/rcodex"
require_relative "support/rate_limits_fixture"

class RCodexTest < Minitest::Test
  include RateLimitsFixture

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
    result = api_payload
    # Explicit null timestamps are valid and keep layout assertions clock-independent.
    result["rateLimits"]["primary"]["resetsAt"] = nil
    result["rateLimits"]["secondary"]["resetsAt"] = nil
    result
  end

  def payload_without_windows
    result = payload
    result["rateLimits"]["primary"] = nil
    result["rateLimits"]["secondary"] = nil
    result
  end

  def cli(server)
    RCodex.cli(output: @output, error: @error, server_factory: -> { server })
  end

  def test_maps_response_with_populated_or_null_bucket_map
    without_buckets = payload.merge("rateLimitsByLimitId" => nil)
    [payload, without_buckets].each do |result|
      snapshot = RCodex::Infrastructure::RateLimitsParser.call(result)
      assert_equal "plus", snapshot.plan_type
      assert_equal [300, 10_080], snapshot.windows.map(&:window_duration_mins)
      assert_equal [75.0, 90.0], snapshot.windows.map(&:remaining_percent)
      assert snapshot.windows.frozen?
    end
  end

  def test_plan_comes_only_from_direct_limits
    result = payload
    result["rateLimitsByLimitId"]["codex"]["planType"] = "pro"
    ["plus", nil].each do |plan|
      result["rateLimits"]["planType"] = plan
      snapshot = RCodex::Infrastructure::RateLimitsParser.call(result)
      plan.nil? ? assert_nil(snapshot.plan_type) : assert_equal(plan, snapshot.plan_type)
      assert_equal 2, snapshot.windows.size
    end
  end

  def test_null_windows_are_empty_but_missing_usage_is_an_error
    assert RCodex::Infrastructure::RateLimitsParser.call(payload_without_windows).empty?
    result = payload
    result["rateLimits"]["primary"].delete("usedPercent")
    assert_raises(RCodex::Infrastructure::InvalidResponseError) { RCodex::Infrastructure::RateLimitsParser.call(result) }
  end

  def test_default_output_and_cleanup
    server = FakeServer.new(result: payload)
    assert_equal 0, cli(server).run(["--usage"])
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
      assert_equal 0, cli(server).run(["--usage", option])
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
    snapshot = RCodex::Infrastructure::RateLimitsParser.call(payload)
    RCodex::Infrastructure::TextRenderer.new(output: @output, env: {}).render(snapshot, simple: true)
    refute_includes @output.string, "\e["
    refute_match(/[█░]/, @output.string)
  end

  def test_simple_output_aligns_generic_labels
    snapshot = RCodex::Domain::RateLimits.new(
      plan_type: nil,
      primary: { window_duration_mins: 15, used_percent: 25, resets_at: nil },
      secondary: { window_duration_mins: nil, used_percent: 100, resets_at: nil }
    )
    RCodex::Infrastructure::TextRenderer.new(output: @output).render(snapshot, simple: true)
    assert_equal "15-min quota:   75.0% left\nQuota:           0.0% left\n", @output.string
  end

  def test_simple_output_without_windows_reports_error
    server = FakeServer.new(result: payload_without_windows)
    assert_equal 1, cli(server).run(["--usage", "--simple"])
    assert_empty @output.string
    assert_includes @error.string, "No Codex rate-limit windows were returned."
    assert server.closed
  end

  def test_simple_and_json_are_mutually_exclusive_before_server_startup
    application = RCodex.cli(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    [["--usage", "--simple", "--json"], ["--json", "-s", "--usage"]].each do |args|
      assert_equal 1, application.run(args)
    end
    assert_empty @output.string
    assert_includes @error.string, "--json and --simple cannot be used together"
  end

  def test_json_preserves_unknown_fields_and_succeeds_without_windows
    result = { "newField" => [1, 2] }
    server = FakeServer.new(result: result)
    assert_equal 0, cli(server).run(["--usage", "--json"])
    assert_equal result, JSON.parse(@output.string)
    assert_empty @error.string
    assert server.closed
  end

  def test_no_windows_is_an_error_in_text_mode
    result = payload_without_windows
    server = FakeServer.new(result: result)
    assert_equal 1, cli(server).run(["--usage"])
    assert_equal "Codex · ChatGPT Plus\n\n", @output.string
    assert_equal "No Codex rate-limit windows were returned.\n\n#{JSON.pretty_generate(result)}\n", @error.string
    assert server.closed
  end

  def test_help_and_invalid_options_do_not_launch_server
    application = RCodex.cli(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    assert_equal 0, application.run(["--help"])
    assert_includes @output.string, "Usage: rcodex --usage [--simple | --json]"
    assert_equal 1, application.run(["--unknown"])
    assert_includes @error.string, "invalid option"
  end

  def test_no_arguments_show_help_without_starting_server
    application = RCodex.cli(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    assert_equal 0, application.run([])
    assert_includes @output.string, "Usage: rcodex --usage"
    assert_empty @error.string
  end

  def test_version_does_not_start_server
    application = RCodex.cli(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    assert_equal 0, application.run(["--version"])
    assert_equal "rcodex #{RCodex::VERSION}\n", @output.string
  end

  def test_format_flags_require_usage_and_positionals_are_rejected
    application = RCodex.cli(
      output: @output, error: @error,
      server_factory: -> { flunk "server should not be started" }
    )
    [["--simple"], ["-s"], ["--json"]].each do |args|
      assert_equal 1, application.run(args)
    end
    assert_includes @error.string, "--usage is required"
    assert_equal 1, application.run(["--usage", "unexpected"])
    assert_includes @error.string, "unexpected arguments"
  end

  def test_usage_option_order_and_arguments_are_preserved
    server = FakeServer.new(result: payload)
    args = ["--simple", "--usage"].freeze
    assert_equal 0, cli(server).run(args)
    assert_equal ["--simple", "--usage"], args
    assert_includes @output.string, "5-hour quota:"
    assert server.closed
  end

  def test_failure_reports_error_and_closes_server
    server = FakeServer.new(error: RCodex::Infrastructure::AppServerError.new("failed"))
    assert_equal 1, cli(server).run(["--usage"])
    assert_equal "Error: failed\n", @error.string
    assert server.closed
  end

  def test_startup_failure_reports_error
    application = RCodex.cli(
      output: @output, error: @error,
      server_factory: -> { raise RCodex::Infrastructure::AppServerError, "missing executable" }
    )
    assert_equal 1, application.run(["--usage"])
    assert_equal "Error: missing executable\n", @error.string
  end

  def test_renderer_handles_generic_durations_resets_and_out_of_range_usage
    timestamp = Time.local(2025, 1, 2, 3, 4)
    snapshot = RCodex::Domain::RateLimits.new(
      plan_type: nil,
      primary: { window_duration_mins: 2880, used_percent: -10, resets_at: timestamp.to_i },
      secondary: { window_duration_mins: 120, used_percent: 110, resets_at: timestamp.to_i }
    )
    RCodex::Infrastructure::TextRenderer.new(output: @output, clock: -> { timestamp - 172_800 }).render(snapshot)
    assert_includes @output.string, "2-day quota    #{'█' * 20}    110% left"
    assert_includes @output.string, "2-hour quota   #{'░' * 20}    -10% left"
    assert_equal 2, @output.string.scan("Resets Thu, Jan 2 at 03:04").size
  end

  def test_terminal_colors_follow_remaining_quota_and_preserve_layout
    { 100 => 32, 31 => 32, 30 => 33, 11 => 33, 10 => 31, 0 => 31 }.each do |remaining, code|
      snapshot = RCodex::Domain::RateLimits.new(
        plan_type: "plus",
        primary: { window_duration_mins: 300, used_percent: 100 - remaining, resets_at: nil },
        secondary: nil
      )
      terminal = StringIO.new
      terminal.define_singleton_method(:tty?) { true }
      plain = StringIO.new
      RCodex::Infrastructure::TextRenderer.new(output: terminal, env: {}).render(snapshot)
      RCodex::Infrastructure::TextRenderer.new(output: plain, env: {}).render(snapshot)

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
      snapshot = RCodex::Infrastructure::RateLimitsParser.call(payload)
      RCodex::Infrastructure::TextRenderer.new(output: terminal, env: env).render(snapshot)
      refute_includes terminal.string, "\e["
    end
  end

  def test_json_is_plain_even_on_a_terminal
    @output.define_singleton_method(:tty?) { true }
    assert_equal 0, cli(FakeServer.new(result: payload)).run(["--usage", "--json"])
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
      snapshot = RCodex::Domain::RateLimits.new(
        plan_type: nil,
        primary: { window_duration_mins: 300, used_percent: 25, resets_at: (now + seconds).to_i },
        secondary: nil
      )
      RCodex::Infrastructure::TextRenderer.new(output: output, clock: -> { now }).render(snapshot)
      assert_includes output.string, "     75% left"
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
        abort "wrong client" unless message.dig("params", "clientInfo", "name") == "rcodex"
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
    server = RCodex::Infrastructure::AppServer.new(command: [RbConfig.ruby, "-e", SERVER, mode])
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
      error = assert_raises(RCodex::Infrastructure::AppServerError) { server.rate_limits }
      assert_includes error.message, "denied"
      assert_includes error.message, "42"
    end
  end

  def test_unexpected_exit_includes_stderr
    with_server("exit") do |server|
      error = assert_raises(RCodex::Infrastructure::AppServerError) { server.rate_limits }
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
    error = assert_raises(RCodex::Infrastructure::AppServerError) do
      RCodex::Infrastructure::AppServer.new(command: ["/nonexistent/rcodex-test"])
    end
    assert_includes error.message, "was not found in PATH"
  end
end
