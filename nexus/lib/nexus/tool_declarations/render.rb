module Nexus
  module ToolDeclarations
    # THE PROFILE'S RENDER: a declared set's kernel entries with every
    # tool-name macro spelled in the set's own names. An ALIAS entry —
    # `{name, canonical, params?, omit?, description?}` — becomes a full
    # function block (the alias's name, the kernel's text or its own, the
    # kernel's parameters mapped) with its resolution facts beside it; a
    # PLAIN kernel entry in a set that holds an alias is re-rendered so its
    # text names the alias (spawn says `Agent` on a claude profile). A
    # set with no alias renders to the catalog's bytes, untouched. Pure: a
    # function of the stored set, idempotent, so a re-declaration of the
    # same set is the same bytes.
    module Render
      # The keys an alias entry carries beside its function block; stripped
      # by `ToolDeclarations.wire` before a provider sees the set.
      ALIAS_KEYS = %w[canonical params omit description].freeze

      class << self
        # The un-aliased render: every macro spelled as the kernel's wire name.
        def plain(template) = Nexus::ToolRegistry.render_text(template)

        # The stored form of a set. Entries that are neither kernel tools
        # nor aliases pass through untouched, in place.
        def render(entries)
          entries = Array(entries)
          return entries unless entries.any? { |entry| ToolDeclarations.alias?(entry) }

          map = spellings(entries)
          entries.map do |entry|
            if entry.key?("route") then entry
            elsif ToolDeclarations.alias?(entry) then alias_entry(entry, map)
            elsif (canonical = kernel_canonical(entry)) then kernel_entry(canonical, map).merge(entry.slice(*ToolDeclarations::PRESENTATION_FIELDS))
            else entry
            end
          end
        end

        # A plain kernel entry as this set spells it: the catalog's bytes
        # when the set holds no alias.
        def kernel_entry(canonical, spellings)
          tool = Nexus::ToolRegistry.entry(canonical)
          function_block(tool, tool.name, tool.template, tool.parameter_template, spellings)
        end

        # An alias's function definition: `{type, function}` alone.
        def function_definition(canonical, name:, params: nil, omit: nil, description: nil, spellings: {})
          tool = Nexus::ToolRegistry.entry(canonical)
          own = spellings.merge(tool.name => name)
          template = description.nil? ? tool.template : description
          parameters = alias_parameters(tool.parameter_template, Hash.try_convert(params) || {},
            Array(omit).map(&:to_s))
          function_block(tool, name, template, parameters, own)
        end

        # THE PREFERENCE RULE: for every kernel wire name, the set's
        # spelling — the plain name when declared, else the first alias by
        # name, else the kernel's own (a canonical nobody declared is still
        # mentioned by the texts that neighbour it).
        def spellings(entries)
          declared = Array(entries).group_by { |entry| ToolDeclarations.canonical_of(entry) }
          Nexus::ToolRegistry::LIVE.values.to_h do |tool|
            spellings = declared.fetch(tool.canonical, [])
            plain = spellings.any? { |entry| ToolDeclarations.name_of(entry) == tool.name }
            aliases = spellings.select { |entry| ToolDeclarations.alias?(entry) }
              .map { |entry| ToolDeclarations.name_of(entry).to_s }.sort
            [tool.name, (plain || aliases.empty?) ? tool.name : aliases.first]
          end
        end

        private

          def kernel_canonical(entry)
            canonical = ToolDeclarations.canonical_of(entry)
            canonical if canonical && Nexus::ToolRegistry.kernel_name?(canonical)
          end

          def alias_entry(entry, spellings)
            canonical = Nexus::ToolRegistry.resolve(entry["canonical"])
            definition = function_definition(canonical,
              name: ToolDeclarations.name_of(entry), params: entry["params"], omit: entry["omit"],
              description: entry["description"], spellings: spellings)
            facts = entry.slice(*ALIAS_KEYS).merge("canonical" => canonical).compact_blank
            definition.merge(facts).merge(entry.slice(*ToolDeclarations::PRESENTATION_FIELDS))
          end

          def function_block(tool, name, template, parameters, spellings)
            {
              "type" => "function",
              "function" => {
                "name" => name,
                "description" => Nexus::ToolRegistry.render_text(template, spellings),
                "parameters" => Nexus::ToolRegistry.render_schema(parameters, spellings),
              },
            }
          end

          # The kernel's parameters under the alias: each mapped parameter
          # renamed IN PLACE (the prefix keeps its order) with its `default`
          # inverted when the map inverts and its description replaced when
          # the map gives one; each omitted parameter gone; `required`
          # renamed with them.
          def alias_parameters(schema, params, omit)
            properties = Hash.try_convert(schema["properties"]) or return schema
            renames = params.to_h { |alias_param, spec| [spec["maps_to"], alias_param] }
            mapped = properties.each_with_object({}) do |(kernel_param, property), out|
              next if omit.include?(kernel_param)

              alias_param = renames[kernel_param]
              out[alias_param || kernel_param] =
                alias_param ? alias_property(property, params.fetch(alias_param)) : property
            end
            required = Array(schema["required"]).reject { |name| omit.include?(name) }
              .map { |name| renames.fetch(name, name) }
            schema.merge("properties" => mapped, "required" => required)
              .then { |rendered| schema.key?("required") ? rendered : rendered.except("required") }
          end

          # The description given here is a template too; `function_block`
          # renders the whole schema once.
          def alias_property(property, spec)
            property = property.merge("default" => !property["default"]) if
              spec["invert"] && [true, false].include?(property["default"])
            return property if spec["description"].nil?

            property.merge("description" => spec["description"])
          end
      end
    end
  end
end
