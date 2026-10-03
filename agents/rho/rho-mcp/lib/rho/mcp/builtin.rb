require_relative "settings"

module Rho
  module Mcp
    # THE SHIPPED EXAMPLE: Context7 (`https://mcp.context7.com/mcp`) rides in every rho as
    # ONE row of `mcp_servers` the gem carries — PRESENT and DISABLED. rho's `Config` keeps
    # the table opaque (it reads nothing inside `mcp_servers`), so the row lives HERE, in
    # the gem that owns the grammar, and is merged UNDER the person's table the way
    # `checkpoints` merges its defaults under the person's object: the person's rows first,
    # in their order; the shipped row after, unless the person named its key — then their
    # row OVERLAYS it member by member (`{"enabled": true}` is what `rho mcp enable
    # context7` writes; `{"tools": ["get-library-docs"]}` narrows it), never replaces it
    # whole. A value that is not an object passes through untouched to the grammar's own
    # refusal (`Settings::Malformed`). A disabled row is listed by `rho mcp` with the
    # switch, connected to never, announced never; the probe and the login reach it by name
    # all the same.
    #
    # One row, no registry of examples: an example earns its place by being
    # the one a person is told to enable.
    module Builtin
      ROWS = {
        "context7" => {
          "transport" => "http",
          "url" => "https://mcp.context7.com/mcp",
          "tools" => Settings::ALL_TOOLS,
          "enabled" => false,
        }.freeze,
      }.freeze

      module_function

      # `table` is the person's `mcp_servers` (or anything they wrote);
      # answers a new table, the person's untouched.
      def under(table)
        person = Hash.try_convert(table)
        return table if person.nil?

        person = person.to_h { |key, row| [key.to_s, row] }
        person.merge(ROWS.to_h { |key, row| [key, overlaid(row, person, key)] })
      end

      def overlaid(row, person, key)
        return row unless person.key?(key)

        override = Hash.try_convert(person[key])
        override.nil? ? person[key] : row.merge(override.to_h.transform_keys(&:to_s))
      end
    end
  end
end
