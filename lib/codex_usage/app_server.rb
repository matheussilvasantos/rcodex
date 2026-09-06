# frozen_string_literal: true

require "json"
require "open3"
require_relative "domain"

module CodexUsage
  class AppServerError < StandardError; end

  # Translates the upstream schema at the boundary, keeping it out of the domain.
  class RateLimitsMapper
    def self.call(result)
      limits = result["rateLimits"] || result.dig("rateLimitsByLimitId", "codex") || {}
      plan = limits["planType"] || result.dig("rateLimitsByLimitId", "codex", "planType")
      windows = %w[primary secondary].filter_map do |name|
        window = limits[name]
        next unless window

        RateLimitWindow.new(
          duration_minutes: window["windowDurationMins"],
          used_percent: window["usedPercent"],
          resets_at: window["resetsAt"]
        )
      end

      UsageSnapshot.new(plan: plan, windows: windows)
    end
  end

  # Synchronous adapter for Codex's newline-delimited request/response protocol.
  class AppServer
    def initialize(command: ["codex", "app-server", "--stdio"])
      @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(*command)
      # Drain stderr concurrently so a full pipe cannot block the server.
      @stderr_reader = Thread.new { @stderr.read }
      @next_id = 0
      @initialized = false
      @closed = false
    rescue Errno::ENOENT
      raise AppServerError, "`#{command.first}` was not found in PATH."
    end

    def rate_limits
      initialize_protocol unless @initialized
      request("account/rateLimits/read")
    end

    def close
      return if @closed

      @closed = true
      @stdin.close unless @stdin.closed?
      terminate("TERM")
      unless @wait_thread.join(1)
        terminate("KILL")
        @wait_thread.join
      end
    ensure
      if @closed
        @stderr_reader.kill
        @stderr_reader.join
        [@stdout, @stderr].each { |io| io.close unless io.closed? }
      end
    end

    private

    def initialize_protocol
      request(
        "initialize",
        params: { clientInfo: { name: "codex-usage", version: "1.0.0" } }
      )
      send_message(method: "initialized", params: {})
      @initialized = true
    end

    def request(method, params: nil)
      @next_id += 1
      id = @next_id
      message = { id: id, method: method }
      message[:params] = params unless params.nil?
      send_message(message)

      loop do
        response = read_message
        next unless response["id"] == id

        if response["error"]
          raise AppServerError, "Codex App Server error:\n#{JSON.pretty_generate(response["error"])}"
        end

        return response["result"]
      end
    end

    def send_message(message)
      @stdin.puts(JSON.generate(message))
      @stdin.flush
    rescue IOError, SystemCallError => e
      raise AppServerError, "Could not write to Codex App Server: #{e.message}"
    end

    def read_message
      loop do
        line = @stdout.gets
        unless line
          # Do not wait indefinitely for stderr if the server closed only stdout.
          error = @stderr_reader.join(0.1) ? @stderr_reader.value : ""
          raise AppServerError, "Codex App Server exited unexpectedly.#{error.empty? ? "" : "\n#{error}"}"
        end

        begin
          response = JSON.parse(line)
          return response if response.is_a?(Hash)
        rescue JSON::ParserError
          # Ignore blank lines and non-JSON diagnostic output.
        end
      end
    end

    def terminate(signal)
      Process.kill(signal, @wait_thread.pid) if @wait_thread.alive?
    rescue Errno::ESRCH
      nil
    end
  end
end
