require "json"
require_relative "settings"

module Rho
  module Mcp
    # Defaults used by raw-row test seams come from the same static schema that
    # the core resolves for production Api#configuration values.
    module Builtin
      DESCRIPTION = JSON.parse(File.read(File.expand_path("../../../rho-extension.json", __dir__)))
        .fetch("configuration_schema").fetch("properties").fetch("servers").fetch("properties")
      ROWS = Ractor.make_shareable(DESCRIPTION.to_h do |key, schema|
        values = schema.fetch("properties").filter_map do |name, field|
          [name, field.fetch("default")] if field.key?("default")
        end.to_h
        [key, values]
      end)
      private_constant :DESCRIPTION

      module_function

      # `table` is the person's `plugins.rho.mcp.configuration.servers` (or anything they wrote);
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
