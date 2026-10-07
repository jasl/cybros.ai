module Rho
  module T3
    Selection = Data.define(:instance_id, :agent, :harness, :model) do
      def native = { "instanceId" => instance_id, "model" => model }
      def report = { "agent" => agent, "harness" => harness, "model" => model }
    end

    # This is a projection of the coding service's current provider directory,
    # not a second model registry. Explicit choices resolve only within it.
    Catalog = Data.define(:providers) do
      HARNESSES = { "codex" => "Codex", "claudeAgent" => "Claude Code", "opencode" => "OpenCode",
        "cursor" => "Cursor", "grok" => "Grok", "pi" => "Pi" }.freeze

      Model = Data.define(:id, :name, :aliases, :default, :custom) do
        def self.parse(value)
          value = value.to_h
          new(id: value.fetch("slug").to_s, name: value.fetch("name").to_s,
            aliases: value.fetch("aliases", []).map(&:to_s), default: value["isDefault"] == true, custom: value["isCustom"] == true)
        end

        def report = { "id" => id, "name" => name, "aliases" => aliases }
      end

      Provider = Data.define(:instance_id, :driver, :name, :harness, :available, :reason, :models) do
        def self.parse(value)
          value = value.to_h
          driver = value.fetch("driver").to_s
          harness = HARNESSES.fetch(driver, driver)
          reason = if value.fetch("enabled") != true
            "disabled"
          elsif value["availability"] == "unavailable"
            "unavailable"
          elsif value.fetch("status") != "ready"
            "not ready (#{value.fetch("status")})"
          end
          new(instance_id: value.fetch("instanceId").to_s, driver: driver,
            name: value.fetch("displayName", harness).to_s, harness: harness,
            available: reason.nil?, reason: reason, models: value.fetch("models").map { |model| Model.parse(model) })
        end

        def default_model
          models.find { |model| model.default && !model.custom } || models.find { |model| !model.custom } || models.first
        end

        def matches?(value)
          [name, harness, driver].any? { |candidate| candidate.casecmp?(value) } ||
            (driver == "claudeAgent" && value.casecmp?("Claude"))
        end

        def report
          { "agent" => name, "harness" => harness, "available" => available, "reason" => reason,
            "default_model" => default_model&.id, "models" => models.map(&:report) }.compact
        end

        def select_model(value)
          value = value.to_s.strip
          choices = if value.empty?
            [default_model].compact
          else
            exact = models.select { |model| model.id == value }
            named = models.select { |model| model.name.casecmp?(value) }
            if exact.any?
              exact
            elsif named.any?
              named
            else
              models.select { |model| model.aliases.any? { |item| item.casecmp?(value) } }
            end
          end
          if choices.length != 1
            raise Error, "Choose an available model for #{name}: #{models.map(&:id).join(", ")}. The requested model was unavailable or ambiguous."
          end

          choices.first.id
        end
      end

      def initialize(providers:)
        super(providers: providers.map { |provider| Provider.parse(provider) })
      rescue KeyError, TypeError, NoMethodError
        raise Error, "The coding service returned an incomplete agent directory", cause: nil
      end

      def report = providers.map(&:report)

      def select(agent: nil, model: nil)
        name = agent.to_s.strip
        choices = name.empty? ? providers.select(&:available) : providers.select { |provider| provider.matches?(name) }
        if choices.length != 1
          raise Error, "Choose one available coding agent with coding_work action=agents; #{name.empty? ? "no agent was selected" : "#{name} was unavailable or ambiguous"}."
        end
        selected = choices.first
        raise Error, "#{selected.name} is #{selected.reason}; choose it after its setup is ready" unless selected.available

        Selection.new(instance_id: selected.instance_id, agent: selected.name, harness: selected.harness,
          model: selected.select_model(model))
      end
    end
  end
end
