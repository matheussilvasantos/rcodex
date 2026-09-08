# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/rcodex/infrastructure/response_normalizer"

class ResponseNormalizerTest < Minitest::Test
  def test_normalizes_nested_hashes_and_arrays_without_mutating_input
    input = {
      "planType" => "plus",
      "primary" => { "usedPercent" => 25, "resetsAt" => nil },
      "extraItems" => [{ "apiURL" => "https://example.test", :isEnabled => false }, 1, nil]
    }
    original = Marshal.load(Marshal.dump(input))

    assert_equal({
      plan_type: "plus",
      primary: { used_percent: 25, resets_at: nil },
      extra_items: [{ api_url: "https://example.test", is_enabled: false }, 1, nil]
    }, RCodex::Infrastructure::ResponseNormalizer.call(input))
    assert_equal original, input
  end

  def test_already_normalized_keys_and_values_are_preserved
    input = { used_percent: 25, resets_at: nil, label: "keepCamelCaseValue" }
    assert_equal input, RCodex::Infrastructure::ResponseNormalizer.call(input)
  end
end
