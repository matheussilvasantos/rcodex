# frozen_string_literal: true

module RCodex
  module Infrastructure
    class TextRenderer
      def initialize(output:, clock: -> { Time.now }, env: ENV)
        @output = output
        @clock = clock
        @color = output.respond_to?(:tty?) && output.tty? &&
                 !env.key?("NO_COLOR") && env["TERM"] != "dumb"
      end

      def render(snapshot, simple: false)
        return render_simple(snapshot) if simple

        @output.puts "Codex#{snapshot.plan_type ? " · ChatGPT #{snapshot.plan_type.capitalize}" : ""}"
        @output.puts

        labels = snapshot.windows.map { |window| duration_name(window.window_duration_mins) }
        label_width = labels.map(&:length).max || 0
        now = @clock.call

        snapshot.windows.each_with_index do |window, index|
          @output.puts if index.positive?
          percent = format("%.1f", window.remaining_percent).delete_suffix(".0")
          @output.printf(
            "%-*s   %s  %s\n",
            label_width, labels[index],
            colorize(bar(window.remaining_percent), window.remaining_percent),
            colorize(format("%5s%% left", percent), window.remaining_percent)
          )
          reset = format_reset(window.resets_at, now: now)
          @output.puts "#{' ' * (label_width + 3)}Resets #{reset}" if reset
        end
      end

      private

      def render_simple(snapshot)
        labels = snapshot.windows.map { |window| "#{duration_name(window.window_duration_mins)}:" }
        width = labels.map(&:length).max || 0
        snapshot.windows.each_with_index do |window, index|
          @output.printf("%-*s  %5.1f%% left\n", width, labels[index], window.remaining_percent)
        end
      end

      def colorize(text, remaining_percent)
        return text unless @color

        code = if remaining_percent <= 10
                 31 # Red: nearly exhausted.
               elsif remaining_percent <= 30
                 33 # Yellow: running low.
               else
                 32 # Green: quota available.
               end
        "\e[#{code}m#{text}\e[0m"
      end

      def duration_name(minutes)
        case minutes
        when 300 then "5-hour quota"
        when 10_080 then "Weekly quota"
        else
          if minutes && minutes % 1_440 == 0
            "#{minutes / 1_440}-day quota"
          elsif minutes && minutes % 60 == 0
            "#{minutes / 60}-hour quota"
          else
            minutes ? "#{minutes}-min quota" : "Quota"
          end
        end
      end

      def format_reset(value, now:)
        return nil unless value

        time = Time.at(value)
        seconds = time - now
        return "now" if seconds <= 0
        return "in less than a minute" if seconds < 60

        if seconds < 86_400
          hours, minutes = (seconds / 60).floor.divmod(60)
          duration = []
          duration << "#{hours}h" if hours.positive?
          duration << "#{minutes}m" if minutes.positive?
          "in #{duration.join(' ')}"
        else
          time.localtime.strftime("%a, %b %-d at %H:%M")
        end
      rescue ArgumentError, RangeError
        value.to_s
      end

      def bar(remaining_percent, width: 20)
        remaining = [[remaining_percent, 0].max, 100].min
        filled = (remaining / 100.0 * width).round
        "█" * filled + "░" * (width - filled)
      end
    end
  end
end
