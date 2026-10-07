module Rho
  class Packages
    # Only the root settings migration calls this reader. Current package reads
    # never consult the retired catalog, even when it remains on disk.
    def self.import_legacy(home, plugins)
      root = File.join(home.extensions_root, "managed")
      catalog = StateFile.new(File.join(root, "catalog.json")).read || {}
      catalog.each_with_object(plugins.dup) do |(name, raw), result|
        name = package_name(name)
        row = raw.to_h
        current = row["active"] || row["previous"]
        if current
          manifest, selection = legacy_selection(root, name, current)
          previous = if row["active"] && row["previous"]
            old_manifest, old_selection = legacy_selection(root, name, row.fetch("previous"))
            unless old_manifest.id == manifest.id
              raise Rho::ConfigurationError, "#{name} previous selection has a different runtime id"
            end
            old_selection
          end
          if result.key?(manifest.id)
            raise Rho::ConfigurationError, "multiple configured sources for plugin #{manifest.id}"
          end
          result[manifest.id] = Entry.new(enabled: !row["active"].nil?, selection: selection, previous: previous).to_h
        end
      end
    rescue KeyError, NoMethodError, TypeError
      raise Rho::StateError, "legacy managed package catalog is malformed", cause: nil
    end

    def self.legacy_selection(root, name, raw)
      row = raw.to_h
      version = version(row.fetch("version"))
      manifest = Manifest.read(File.join(root, name, version))
      unless manifest.name == name
        raise Rho::ConfigurationError, "#{name} installed manifest has a different package name"
      end
      selection = Selection.new(name: name, version: version,
        configuration_version: row.fetch("configuration_version", 1),
        configuration: row.fetch("configuration").to_h, state_schema: row.fetch("state_schema").to_s)
      [manifest, selection]
    end
    private_class_method :legacy_selection
  end
end
