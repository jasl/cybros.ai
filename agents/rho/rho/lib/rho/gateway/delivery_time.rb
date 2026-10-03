require "time"

module Rho
  module Gateway
    # A chat has no implicit machine timezone. Resolve its explicit time once
    # before admission so retrying the same update cannot move a relative delay.
    # Nexus still owns the accepted time bounds and the wake.
    module DeliveryTime
      UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
      AT = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:?\d\d)\z/i
      USAGE = "Use in 20m (s, m, h or d), at an ISO 8601 time with Z or an offset " \
        "(2026-10-03T09:00:00+08:00), or now when rescheduling.".freeze

      def self.resolve(expression, now:)
        mode, value = expression.split(/\s+/, 2)
        time = case mode
        when "now"
          raise Rho::Error, USAGE if value

          Time.at(now)
        when "in"
          Time.at(now + duration_seconds(value))
        when "at"
          raise Rho::Error, USAGE unless value && value.length <= 40 && AT.match?(value)

          Time.iso8601(value)
        else
          raise Rho::Error, USAGE
        end
        time.utc.iso8601
      rescue ArgumentError
        raise Rho::Error, USAGE
      end

      def self.duration_seconds(value)
        match = value.to_s.length <= 10 && /\A(\d{1,9})([smhd])\z/.match(value.to_s)
        raise Rho::Error, USAGE unless match

        Integer(match[1], 10) * UNITS.fetch(match[2])
      end
    end
  end
end
