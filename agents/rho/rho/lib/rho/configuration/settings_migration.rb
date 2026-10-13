module Rho
  module Configuration
    # The only reader of the previous file format. Normal operation consumes
    # current plugin entries exclusively after this one forward conversion.
    module SettingsMigration
      FIELDS = {
        "bash_timeout_seconds" => ["rho.coding", "bash_timeout_seconds"],
        "code_mode" => ["rho.codemode", "default"],
        "compaction" => ["rho.compaction", nil],
        "lifecycle_hooks" => ["rho.lifecycle_hooks", nil],
        "image_model" => ["rho.images", "model"],
        "checkpoints" => ["rho.checkpoints", nil],
        "web" => ["rho.web_tools", nil],
        "mcp_servers" => ["rho.mcp", "servers"],
        "acp_agents" => ["rho.acp-client", "agents"],
        "telegram" => ["rho.ingress_telegram", nil],
        "t3" => ["rho.t3", nil],
      }.freeze

      def self.call(document, home:)
        plugins = document.fetch("plugins", {}).to_h.dup
        FIELDS.each do |key, (id, field)|
          next unless document.key?(key)

          raw = document.fetch(key)
          configuration = field ? { field => raw } : raw.to_h
          if key == "mcp_servers"
            configuration["servers"] = raw.to_h.transform_values do |server|
              server["tools"] == "*" ? server.merge("tools" => ["*"]) : server
            end
          end
          entry = { "configuration_version" => 1, "configuration" => configuration }
          if %w[checkpoints telegram].include?(key)
            entry["enabled"] = configuration.delete("enabled") if configuration.key?("enabled")
          end
          if key == "telegram" && configuration["owner_id"]
            configuration["owner_id"] = configuration["owner_id"].to_s
          end
          if key == "t3"
            configuration = configuration.merge("server" => "host")
            entry["configuration"] = configuration
          end
          plugins[id] = entry.merge(plugins.fetch(id, {}))
        end
        catalog = Extensions::Catalog.new(home: home, entries: plugins)
        document.fetch("extensions", []).each do |feature|
          descriptor = catalog.descriptors.values.find { |row| row.source["feature"] == feature }
          raise ConfigurationError, "No static description for configured extension #{feature}" unless descriptor

          id = descriptor.id
          plugins[id] = plugins.fetch(id, {}).merge("enabled" => true)
        end
        document.fetch("extension_paths", []).each do |path|
          row = JSON.parse(File.read(path.to_s.sub(/\.rb\z/, ".json"))).to_h
          id = Packages.package_name(row.fetch("id"))
          plugins[id] = plugins.fetch(id, {}).merge("enabled" => true,
            "source" => { "kind" => "path", "path" => File.expand_path(path) })
        end
        token_path = File.join(home.root, "telegram", "token.json")
        if File.file?(token_path)
          token = StateFile.new(token_path).read&.fetch("token", nil)
          if token
            id = "rho.ingress_telegram"
            entry = plugins.fetch(id, {})
            plugins[id] = entry.merge("configuration_version" => 1,
              "configuration" => { "token" => token }.merge(entry.fetch("configuration", {})))
          end
        end
        plugins = Packages.import_legacy(home, plugins)
        document.slice(*Config::KEYS).merge("settings_version" => Config::SETTINGS_VERSION, "plugins" => plugins)
      rescue NoMethodError, TypeError, KeyError, JSON::ParserError
        raise ConfigurationError, "previous settings format could not be migrated; the file is unchanged", cause: nil
      end
    end
  end
end
