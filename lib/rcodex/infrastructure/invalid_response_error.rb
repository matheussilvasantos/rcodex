# frozen_string_literal: true

require_relative "../application/error"

module RCodex
  module Infrastructure
    class InvalidResponseError < Application::Error; end
  end
end
