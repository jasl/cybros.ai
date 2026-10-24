require "json"
require "yaml"
require "rho/env"

module Rho
  class AgentPresets
    # Portable configuration has no identity, workspace, audience or memory.
    # The flat form accepts ordinary agent Markdown files; rho exports the full
    # configuration object so null inheritance and explicit empty lists survive.
    module Portable
      DIRECTORIES = %w[.agents/agents .claude/agents].freeze

      module_function

      def load(text, format:, filename: "preset.md")
        text = String.try_convert(text)
        raise Error, "Preset document content must be a string" if text.nil?

        case format
        when "json"
          fields = JSON.parse(text)
          body = nil
        when "md"
          fields, body, = Rho::Env::Skills.frontmatter(text)
          raise Error, fields if fields in String
        else
          raise Error, "format must be md or json"
        end
        fields = Hash.try_convert(fields)
        raise Error, "Preset document must be an object" if fields.nil?

        fields = fields.transform_keys(&:to_s)
        configuration = fields["configuration"]
        if fields.key?("configuration")
          unknown = fields.keys - %w[name description configuration]
          configuration = Hash.try_convert(configuration)&.dup
          raise Error, "configuration must be an object" if configuration.nil?
        else
          unknown = fields.keys - %w[name description system_prompt model model_mode fallback_models tools runner_tool_names mcp prompt_template]
          configuration = fields.except("name", "description")
          %w[tools runner_tool_names].each do |key|
            names = String.try_convert(configuration[key])
            configuration[key] = names.split(",").map(&:strip).reject(&:empty?) if names
          end
          if configuration["model"] == "inherit"
            configuration["model"] = nil
            configuration["model_mode"] = "follow"
          end
        end
        raise Error, "Unsupported Preset fields: #{unknown.join(", ")}" unless unknown.empty?

        configuration["system_prompt"] = body unless body.nil? || body.empty?
        { name: fields.fetch("name", File.basename(filename, File.extname(filename))),
          description: fields.fetch("description"), configuration: configuration }
      rescue JSON::ParserError
        raise Error, "Invalid JSON Preset document"
      rescue KeyError => error
        raise Error, "Required Preset field is missing: #{error.key}"
      end

      def dump(entry, format:)
        configuration = entry.configuration.dup
        fields = { "name" => entry.name, "description" => entry.description, "configuration" => configuration }
        case format
        when "json" then "#{JSON.pretty_generate(fields)}\n"
        when "md"
          prompt = configuration.delete("system_prompt").to_s
          "#{YAML.dump(fields)}---\n#{prompt}"
        else raise Error, "format must be md or json"
        end
      end
    end
  end
end
