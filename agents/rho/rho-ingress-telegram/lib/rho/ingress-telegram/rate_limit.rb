module Rho
  module IngressTelegram
    # Scheduling advice for one bot. The runtime owns coalescing and priorities;
    # every topic in a chat supplies the same chat_id and shares this budget.
    class RateLimit
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @bot_at = 0.0
        @blocked_until = 0.0
        @chat_at = {}
        @preview_at = {}
      end

      def ready?(chat_id:, group:, progress: false, now: @clock.call)
        next_at(chat_id: chat_id, group: group, progress: progress, now: now) <= now
      end

      def next_at(chat_id:, group:, progress: false, now: @clock.call)
        key = chat_id.to_s
        [now, @bot_at, @blocked_until, @chat_at.fetch(key, 0.0),
          progress ? @preview_at.fetch(key, 0.0) : 0.0].max
      end

      def sent(chat_id:, group:, progress: false, now: @clock.call)
        key = chat_id.to_s
        @bot_at = now + 1.0 / 30
        @chat_at[key] = now + (group ? 3.0 : 1.0)
        if progress
          @preview_at[key] = now + (group ? 4.0 : 1.0)
        end
        nil
      end

      # Telegram does not identify the exhausted bucket. Conservatively pause
      # this bot, including final/control messages, for the stated duration.
      def retry_after(seconds, now: @clock.call)
        seconds = Float(seconds)
        unless seconds.finite? && seconds >= 0
          raise ArgumentError, "Telegram retry_after must be finite and nonnegative"
        end
        @blocked_until = [@blocked_until, now + seconds].max
        nil
      end
    end
  end
end
