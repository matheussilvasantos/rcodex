# frozen_string_literal: true

require "json"

module RateLimitsFixture
  # Based on a live response; account/credit identifiers and display data are synthetic.
  def api_payload
    JSON.parse(File.read(File.expand_path("../fixtures/rate_limits.json", __dir__)))
  end
end
