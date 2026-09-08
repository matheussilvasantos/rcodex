# frozen_string_literal: true

require "json"
require "optparse"
require_relative "error"
require_relative "../version"

module RCodex
  module Application
    # Orchestrates the CLI through injected dependencies. Server creation happens
    # only after successful option parsing; concrete adapters are wired elsewhere.
    class CLI
      def initialize(output:, error:, server_factory:, parser:, renderer:)
        @output = output
        @error = error
        @server_factory = server_factory
        @parser = parser
        @renderer = renderer
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

        snapshot = @parser.call(result)
        @renderer.render(snapshot, simple: simple)
        return 0 unless snapshot.empty?

        @error.puts "No Codex rate-limit windows were returned."
        @error.puts
        @error.puts JSON.pretty_generate(result)
        1
      rescue OptionParser::ParseError, Error => e
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
end
