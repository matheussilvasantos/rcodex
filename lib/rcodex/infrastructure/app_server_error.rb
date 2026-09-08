# frozen_string_literal: true

require_relative "../application/error"

module RCodex
  module Infrastructure
    class AppServerError < Application::Error; end
  end
end
