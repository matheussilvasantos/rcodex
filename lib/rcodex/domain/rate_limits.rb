# frozen_string_literal: true

require_relative "window"

module RCodex
  module Domain
    class RateLimits < Dry::Struct
      attribute :plan_type, Types::String.optional
      attribute :primary, Window.optional
      attribute :secondary, Window.optional

      def windows
        [primary, secondary].compact.freeze
      end

      def empty?
        windows.empty?
      end
    end
  end
end
