require "English"

module E2E
  # HOW MANY WORLDS `rake e2e` RUNS AT ONCE, read off the Postgres ceiling. One world peaks at ~29
  # connections steady and ~42 at a spike (Puma, the two hosts, Solid Queue's own, the operator's
  # transient runners — a host rebooting after a pin beside another world's teardown; sampled every
  # 2 s through whole groups, 2026-09-09). A stock `max_connections` of 100 less three reserved
  # admits two worlds (94 of 97 at the peak), as used in CI. Three want the ceiling raised to
  # `max_connections >= 200`. `E2E_WORLDS` in the
  # environment overrides the read; a ceiling that cannot be read (no `psql`, no server) is the
  # stock one.
  module WorldSlots
    STOCK_WORLDS = 2
    RAISED_WORLDS = 3
    RAISED_CEILING = 200

    module_function

    def default(max_connections)
      max_connections && max_connections >= RAISED_CEILING ? RAISED_WORLDS : STOCK_WORLDS
    end

    # One `SHOW max_connections` against the maintenance database, on the
    # same URL base the worlds connect through; nil when it cannot be read.
    def max_connections(psql: "psql", url_base: ENV["RAILS_DB_URL_BASE"])
      target = url_base ? "#{url_base}/postgres" : "postgres"
      output = IO.popen([psql, "-X", "-tA", "-c", "SHOW max_connections", target], err: File::NULL, &:read)
      return nil unless $CHILD_STATUS.success?

      Integer(output.strip)
    rescue SystemCallError, ArgumentError
      nil
    end
  end
end
