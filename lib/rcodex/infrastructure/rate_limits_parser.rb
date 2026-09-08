# frozen_string_literal: true

require_relative "../domain/rate_limits"
require_relative "response_normalizer"
require_relative "invalid_response_error"

module RCodex
  module Infrastructure
    # Normalizes and validates API data without translating to a second model.
    class RateLimitsParser
      def self.call(result)
        unless result.is_a?(Hash)
          raise InvalidResponseError, "Invalid Codex rate-limit response: expected an object"
        end

        attributes = ResponseNormalizer.call(result.fetch("rateLimits"))
        Domain::RateLimits.new(attributes)
      rescue KeyError, Dry::Struct::Error => e
        raise InvalidResponseError, "Invalid Codex rate-limit response: #{e.message}"
      end
    end
  end
end
