# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../../lib/rcodex/application/cli"

class ApplicationCLITest < Minitest::Test
  class FakeServer
    attr_reader :closed

    def rate_limits
      { "raw" => true }
    end

    def close
      @closed = true
    end
  end

  def test_orchestrates_injected_dependencies_without_concrete_adapters
    server = FakeServer.new
    snapshot = Object.new
    snapshot.define_singleton_method(:empty?) { false }
    calls = []
    parser = lambda do |result|
      assert server.closed
      assert_equal({ "raw" => true }, result)
      calls << :parse
      snapshot
    end
    renderer = Object.new
    renderer.define_singleton_method(:render) do |value, simple:|
      calls << [:render, value, simple]
    end
    error = StringIO.new
    cli = RCodex::Application::CLI.new(
      output: StringIO.new, error: error,
      server_factory: -> { server }, parser: parser, renderer: renderer
    )

    assert_equal 0, cli.run(["--usage", "--simple"])
    assert_equal [:parse, [:render, snapshot, true]], calls
    assert_empty error.string
  end

  def test_json_bypasses_parsing_and_rendering
    server = FakeServer.new
    output = StringIO.new
    parser = ->(_) { flunk "JSON must not be parsed into models" }
    cli = RCodex::Application::CLI.new(
      output: output, error: StringIO.new,
      server_factory: -> { server }, parser: parser, renderer: Object.new
    )

    assert_equal 0, cli.run(["--usage", "--json"])
    assert_equal({ "raw" => true }, JSON.parse(output.string))
    assert server.closed
  end

  def test_dependency_failures_use_the_application_error_contract
    error = StringIO.new
    cli = RCodex::Application::CLI.new(
      output: StringIO.new, error: error,
      server_factory: -> { raise RCodex::Application::Error, "unavailable" },
      parser: Object.new, renderer: Object.new
    )

    assert_equal 1, cli.run(["--usage"])
    assert_equal "Error: unavailable\n", error.string
  end
end
