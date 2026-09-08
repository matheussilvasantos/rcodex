# frozen_string_literal: true

require_relative "rcodex/version"
require_relative "rcodex/application/cli"
require_relative "rcodex/infrastructure/app_server"
require_relative "rcodex/infrastructure/rate_limits_parser"
require_relative "rcodex/infrastructure/text_renderer"

module RCodex
  # Composition root: the only place that selects concrete application adapters.
  def self.cli(output: $stdout, error: $stderr, server_factory: -> { Infrastructure::AppServer.new })
    Application::CLI.new(
      output: output,
      error: error,
      server_factory: server_factory,
      parser: Infrastructure::RateLimitsParser,
      renderer: Infrastructure::TextRenderer.new(output: output)
    )
  end
end
