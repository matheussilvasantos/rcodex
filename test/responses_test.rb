# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../lib/rcodex"
require_relative "support/rate_limits_fixture"

class ResponsesTest < Minitest::Test
  include RateLimitsFixture

  def test_response_is_parsed_into_nested_dry_structs
    attributes = RCodex::Infrastructure::ResponseNormalizer.call(api_payload.fetch("rateLimits"))
    limits = RCodex::Domain::RateLimits.new(attributes)
    assert_kind_of Dry::Struct, limits
    assert_instance_of RCodex::Domain::RateLimits, limits
    assert_equal "plus", limits.plan_type
    assert_instance_of RCodex::Domain::Window, limits.primary
    assert_equal 300, limits.primary.window_duration_mins
    assert_equal 25, limits.primary.used_percent
    assert_equal 1788754899, limits.primary.resets_at
    assert_instance_of RCodex::Domain::Window, limits.secondary
    assert_equal 10, limits.secondary.used_percent
    assert_equal 10080, limits.secondary.window_duration_mins
  end

  def test_key_normalization_handles_camel_case_and_symbol_keys
    attributes = minimal_payload.fetch("rateLimits")
    attributes[:plan_type] = attributes.delete("planType")
    limits = RCodex::Domain::RateLimits.new(RCodex::Infrastructure::ResponseNormalizer.call(attributes))
    assert_equal "plus", limits.plan_type
    assert_equal 300, limits.primary.window_duration_mins
  end

  def test_structs_expect_normalized_keys
    assert_equal Dry::Struct, RCodex::Domain::RateLimits.superclass
    assert_equal Dry::Struct, RCodex::Domain::Window.superclass
    assert_raises(Dry::Struct::Error) do
      RCodex::Domain::RateLimits.new(api_payload.fetch("rateLimits"))
    end
  end

  def test_parser_returns_the_response_model_used_by_the_output
    snapshot = RCodex::Infrastructure::RateLimitsParser.call(minimal_payload)
    assert_instance_of RCodex::Domain::RateLimits, snapshot
    assert_kind_of Dry::Struct, snapshot
    assert_instance_of RCodex::Domain::Window, snapshot.windows.first
    assert_kind_of Dry::Struct, snapshot.windows.first
    assert_equal 75, snapshot.windows.first.remaining_percent
    assert_same snapshot.primary, snapshot.windows.first
    assert_same snapshot.secondary, snapshot.windows.last
    refute snapshot.empty?
    assert_equal RCodex::Infrastructure::RateLimitsParser.call(api_payload), snapshot
  end

  def test_every_modeled_key_is_required_including_nullable_keys
    [[], ["rateLimits"], ["rateLimits", "primary"], ["rateLimits", "secondary"]].each do |path|
      original = minimal_payload
      object = path.empty? ? original : original.dig(*path)
      object.each_key do |key|
        result = minimal_payload
        target = path.empty? ? result : result.dig(*path)
        target.delete(key)
        error = assert_raises(RCodex::Infrastructure::InvalidResponseError, "Missing #{(path + [key]).join('.')}") do
          RCodex::Infrastructure::RateLimitsParser.call(result)
        end
        assert_includes error.message, "Invalid Codex rate-limit response:"
      end
    end
  end

  def test_explicit_nulls_are_accepted_for_api_nullable_values
    [
      ["rateLimits", "primary"], ["rateLimits", "secondary"], ["rateLimits", "planType"],
      ["rateLimits", "primary", "windowDurationMins"], ["rateLimits", "primary", "resetsAt"]
    ].each do |path|
      result = minimal_payload
      set_value(result, path, nil)
      assert_instance_of RCodex::Domain::RateLimits, RCodex::Infrastructure::RateLimitsParser.call(result)
    end
  end

  def test_invalid_response_shapes_and_used_field_types_are_reported
    [nil, [], "invalid", {}].each do |result|
      assert_raises(RCodex::Infrastructure::InvalidResponseError) { RCodex::Infrastructure::RateLimitsParser.call(result) }
    end
    [
      [["rateLimits"], nil], [["rateLimits"], []],
      [["rateLimits", "primary"], []], [["rateLimits", "planType"], 123],
      [["rateLimits", "primary", "windowDurationMins"], "300"],
      [["rateLimits", "primary", "usedPercent"], nil],
      [["rateLimits", "primary", "usedPercent"], "25"],
      [["rateLimits", "primary", "usedPercent"], 25.5],
      [["rateLimits", "primary", "resetsAt"], "2025-01-02T03:04:00Z"]
    ].each do |path, value|
      result = minimal_payload
      set_value(result, path, value)
      error = assert_raises(RCodex::Infrastructure::InvalidResponseError, "Invalid #{path.join('.')}: #{value.inspect}") do
        RCodex::Infrastructure::RateLimitsParser.call(result)
      end
      assert_includes error.message, "Invalid Codex rate-limit response:"
    end
  end

  def test_unused_fields_are_ignored_without_validation_or_mutation
    result = api_payload
    result["rateLimitsByLimitId"] = "not needed"
    result["rateLimitResetCredits"] = "not needed"
    result["rateLimits"]["credits"] = "not needed"
    result["rateLimits"]["primary"]["newField"] = [1, 2]
    original = Marshal.load(Marshal.dump(result))
    attributes = RCodex::Infrastructure::ResponseNormalizer.call(result.fetch("rateLimits"))
    limits = RCodex::Domain::RateLimits.new(attributes)
    assert_equal %i[plan_type primary secondary], limits.to_h.keys
    assert_equal %i[window_duration_mins used_percent resets_at], limits.primary.to_h.keys
    assert_equal RCodex::Infrastructure::RateLimitsParser.call(minimal_payload), RCodex::Infrastructure::RateLimitsParser.call(result)
    assert_equal original, result
  end

  def test_domain_rejects_invalid_attributes
    assert_raises(Dry::Struct::Error) do
      RCodex::Domain::Window.new(window_duration_mins: [], used_percent: 0, resets_at: nil)
    end
    assert_raises(Dry::Struct::Error) do
      RCodex::Domain::RateLimits.new(plan_type: nil, primary: "invalid", secondary: nil)
    end
  end

  def test_windows_skip_nulls_and_empty_reports_no_windows
    window = RCodex::Domain::Window.new(window_duration_mins: 300, used_percent: 25, resets_at: nil)
    [[window, nil], [nil, window], [nil, nil]].each do |primary, secondary|
      limits = RCodex::Domain::RateLimits.new(plan_type: nil, primary: primary, secondary: secondary)
      assert_equal [primary, secondary].compact, limits.windows
      assert_equal primary.nil? && secondary.nil?, limits.empty?
    end
  end

  def test_missing_usage_is_a_cli_error_but_json_still_prints_raw_payload
    result = api_payload
    result["rateLimits"]["primary"].delete("usedPercent")
    server = Struct.new(:result, :closed) do
      def rate_limits
        result
      end

      def close
        self.closed = true
      end
    end.new(result, false)
    output = StringIO.new
    error = StringIO.new
    cli = RCodex.cli(output: output, error: error, server_factory: -> { server })
    assert_equal 1, cli.run(["--usage"])
    assert_includes error.string, "Invalid Codex rate-limit response:"
    assert_empty output.string
    assert server.closed

    assert_equal 0, cli.run(["--usage", "--json"])
    assert_equal result, JSON.parse(output.string)
  end

  private

  def minimal_payload
    { "rateLimits" => api_payload.fetch("rateLimits").slice("planType", "primary", "secondary") }
  end

  def set_value(result, path, value)
    target = path.length == 1 ? result : result.dig(*path[0...-1])
    target[path.last] = value
  end
end
