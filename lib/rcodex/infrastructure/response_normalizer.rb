# frozen_string_literal: true

require "dry-inflector"

module RCodex
  module Infrastructure
    class ResponseNormalizer
      INFLECTOR = Dry::Inflector.new
      private_constant :INFLECTOR

      def self.call(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), normalized|
            normalized[INFLECTOR.underscore(key.to_s).to_sym] = call(item)
          end
        when Array
          value.map { |item| call(item) }
        else
          value
        end
      end
    end
  end
end
