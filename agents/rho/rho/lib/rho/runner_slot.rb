require "time"

module Rho
  # THE THREE-STATE RUNNER SLOT: what a terminal
  # prints beside a host about the runner its tool calls land on, from the
  # KERNEL's presence word for a FOREIGN executor — display, never a gate.
  # None bound says what will fail and how to pick one; offline says the
  # calls wait and which verb moves them; not yet seen says the calls
  # wait; online says nothing, which is the ordinary case. rho's OWN
  # planes print local truth elsewhere (`rho status`).
  module RunnerSlot
    NONE = "none — environment tools will fail; pick one with rho runners use ID".freeze
    OFFLINE_HINT = "— accepted tool calls wait for this Runner".freeze
    NOT_YET_SEEN_HINT = "— tool calls wait for it".freeze

    module_function

    # The line after its label, or nil when there is nothing worth a line.
    # `runner` is the `runner:` document a daemon answers — nil for none
    # bound — with `executor_public_id`, `presence` and `last_seen_at`.
    def line(runner, now: Time.now)
      return NONE if runner.nil?

      runner = Hash.try_convert(runner) || {}
      id = runner["executor_public_id"] || runner[:executor_public_id]
      case runner["presence"] || runner[:presence]
      when "offline"
        "#{id} #{presence_word("offline", runner["last_seen_at"] || runner[:last_seen_at], now: now)} #{OFFLINE_HINT}"
      when "not_yet_seen" then "#{id} not yet seen #{NOT_YET_SEEN_HINT}"
      else nil
      end
    end

    # The one word per presence state: `online`, `offline (last
    # seen 3m ago)`, `not yet seen`; a Nexus that says nothing prints so.
    def presence_word(presence, last_seen_at, now: Time.now)
      case presence
      when "online" then "online"
      when "offline"
        age = age_of(last_seen_at, now: now)
        age ? "offline (last seen #{age} ago)" : "offline"
      when "not_yet_seen" then "not yet seen"
      when nil then "(presence unknown)"
      else presence.to_s
      end
    end

    # `3m`, `12s`, `2h`, `4d` — the coarsest unit that is not zero, floored.
    def age_of(last_seen_at, now: Time.now)
      return nil if last_seen_at.nil?

      seconds = (now - Time.iso8601(last_seen_at.to_s)).floor
      return "#{seconds.clamp(0..)}s" if seconds < 60
      return "#{seconds / 60}m" if seconds < 3600
      return "#{seconds / 3600}h" if seconds < 86_400

      "#{seconds / 86_400}d"
    rescue ArgumentError
      nil
    end
  end
end
