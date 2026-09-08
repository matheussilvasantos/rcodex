# frozen_string_literal: true

require "dry-struct"
require_relative "types"

module RCodex
  module Domain
    class Window < Dry::Struct
      attribute :window_duration_mins, Types::Integer.optional
      attribute :used_percent, Types::Integer
      attribute :resets_at, Types::Integer.optional

      def remaining_percent
        100 - used_percent
      end
    end
  end
end
