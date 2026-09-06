# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require_relative "app_server"

module RCodex
  class TextRenderer
    def initialize(output:, clock: -> { Time.now }, env: ENV)
      @output = output
      @clock = clock
      @color = output.respond_to?(:tty?) && output.tty? &&
               !env.key?("NO_COLOR") && env["TERM"] != "dumb"
    end

    def render(snapshot, simple: false)
      return render_simple(snapshot) if simple

      @output.puts "Codex#{snapshot.plan ? " · ChatGPT #{snapshot.plan.capitalize}" : ""}"
      @output.puts

      labels = snapshot.windows.map { |window| duration_name(window.duration_minutes) }
      label_width = labels.map(&:length).max || 0
      now = @clock.call

      snapshot.windows.each_with_index do |window, index|
        @output.puts if index.positive?
        percent = format("%.1f", window.remaining_percent).delete_suffix(".0")
        @output.printf(
          "%-*s   %s  %s\n",
          label_width, labels[index],
          colorize(bar(window.remaining_percent), window.remaining_percent),
          colorize(format("%5s%% left", percent), window.remaining_percent)
        )
        reset = format_reset(window.resets_at, now: now)
        @output.puts "#{' ' * (label_width + 3)}Resets #{reset}" if reset
      end
    end

    private

    def render_simple(snapshot)
      labels = snapshot.windows.map { |window| "#{duration_name(window.duration_minutes)}:" }
      width = labels.map(&:length).max || 0
      snapshot.windows.each_with_index do |window, index|
        @output.printf("%-*s  %5.1f%% left\n", width, labels[index], window.remaining_percent)
      end
    end

    def colorize(text, remaining_percent)
      return text unless @color

      code = if remaining_percent <= 10
               31 # Red: nearly exhausted.
             elsif remaining_percent <= 30
               33 # Yellow: running low.
             else
               32 # Green: quota available.
             end
      "\e[#{code}m#{text}\e[0m"
    end

    def duration_name(minutes)
      case minutes
      when 300 then "5-hour quota"
      when 10_080 then "Weekly quota"
      else
        if minutes && minutes % 1_440 == 0
          "#{minutes / 1_440}-day quota"
        elsif minutes && minutes % 60 == 0
          "#{minutes / 60}-hour quota"
        else
          minutes ? "#{minutes}-min quota" : "Quota"
        end
      end
    end

    def format_reset(value, now:)
      return nil unless value

      time = case value
             when Numeric then Time.at(value)
             when String then Time.parse(value)
             else return value.to_s
             end
      seconds = time - now
      return "now" if seconds <= 0
      return "in less than a minute" if seconds < 60

      if seconds < 86_400
        hours, minutes = (seconds / 60).floor.divmod(60)
        duration = []
        duration << "#{hours}h" if hours.positive?
        duration << "#{minutes}m" if minutes.positive?
        "in #{duration.join(' ')}"
      else
        time.localtime.strftime("%a, %b %-d at %H:%M")
      end
    rescue ArgumentError, RangeError
      value.to_s
    end

    def bar(remaining_percent, width: 20)
      remaining = [[remaining_percent, 0].max, 100].min
      filled = (remaining / 100.0 * width).round
      "█" * filled + "░" * (width - filled)
    end
  end

  # Application entry point. Dependencies are injected to avoid launching Codex
  # in tests; process creation happens only after successful option parsing.
  class CLI
    def initialize(output: $stdout, error: $stderr, server_factory: -> { AppServer.new })
      @output = output
      @error = error
      @server_factory = server_factory
    end

    def run(argv)
      usage = false
      json = false
      simple = false
      help = false
      version = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rcodex --usage [--simple | --json]"
        opts.on("--usage", "Show Codex rate-limit usage") { usage = true }
        opts.on("--json", "Print the raw JSON response") { json = true }
        opts.on("-s", "--simple", "Print plain, one-line-per-quota output") { simple = true }
        opts.on("-h", "--help", "Show this help") { help = true }
        opts.on("-v", "--version", "Show the version") { version = true }
      end
      remaining = parser.parse(argv)
      unless remaining.empty?
        raise OptionParser::InvalidArgument, "unexpected arguments: #{remaining.join(' ')}"
      end
      if help || argv.empty?
        @output.puts parser
        return 0
      end

      if version
        @output.puts "rcodex #{VERSION}"
        return 0
      end

      raise OptionParser::MissingArgument, "--usage is required" unless usage

      if json && simple
        raise OptionParser::InvalidOption, "--json and --simple cannot be used together"
      end

      result = fetch_rate_limits
      if json
        @output.puts JSON.pretty_generate(result)
        return 0
      end

      snapshot = RateLimitsMapper.call(result)
      TextRenderer.new(output: @output).render(snapshot, simple: simple)
      return 0 unless snapshot.empty?

      @error.puts "No Codex rate-limit windows were returned."
      @error.puts
      @error.puts JSON.pretty_generate(result)
      1
    rescue OptionParser::ParseError, AppServerError => e
      @error.puts "Error: #{e.message}"
      1
    end

    private

    def fetch_rate_limits
      server = @server_factory.call
      server.rate_limits
    ensure
      server&.close
    end
  end
end
