module Rho
  class Packages
    Source = Data.define(:path, :revision, :configuration, :id, :configuration_version)

    Selection = Data.define(:name, :version, :configuration_version, :configuration, :state_schema) do
      def self.from_h(value)
        row = value.to_h
        source = row.fetch("source").to_h
        unless source.fetch("kind") == "package"
          raise Rho::ConfigurationError, "managed package selections require a package source"
        end
        new(name: Packages.package_name(source.fetch("name")), version: Packages.version(source.fetch("version")),
          configuration_version: row.fetch("configuration_version"), configuration: row.fetch("configuration").to_h,
          state_schema: row.fetch("state_schema").to_s)
      end

      def to_h
        { "source" => { "kind" => "package", "name" => name, "version" => version },
          "configuration_version" => configuration_version, "configuration" => configuration, "state_schema" => state_schema }
      end
    end

    Entry = Data.define(:enabled, :selection, :previous) do
      def self.from_h(value)
        row = value.to_h
        new(enabled: row["enabled"], selection: Selection.from_h(row),
          previous: row["previous"] && Selection.from_h(row.fetch("previous")))
      end

      def enabled?(default:) = enabled.nil? ? default : enabled == true

      def to_h
        result = selection.to_h
        unless enabled.nil?
          result["enabled"] = enabled
        end
        if previous
          result["previous"] = previous.to_h
        end
        result
      end
    end
  end
end
