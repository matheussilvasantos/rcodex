# frozen_string_literal: true

module CodexUsage
  # A quota measured over a rolling time window. Presentation belongs elsewhere.
  class RateLimitWindow
    attr_reader :duration_minutes, :used_percent, :resets_at

    def initialize(duration_minutes:, used_percent:, resets_at:)
      @duration_minutes = duration_minutes
      @used_percent = used_percent.to_f
      @resets_at = resets_at
      freeze
    end

    def remaining_percent
      100 - used_percent
    end
  end

  class UsageSnapshot
    attr_reader :plan, :windows

    def initialize(plan:, windows:)
      @plan = plan
      @windows = windows.dup.freeze
      freeze
    end

    def empty?
      windows.empty?
    end
  end
end
