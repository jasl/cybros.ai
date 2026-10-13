module CybrosAgent
  module ModelAdaptations
    # THE ALIAS ENTRY GRAMMAR one preset alias and one row's
    # `tool_descriptions` entry share: `{name, canonical, params?, omit?,
    # description? | recut?}` — the kernel's alias shape with ONE addition,
    # `recut: {anchor, replacement}`, the anchored edit of the served
    # template that stands in for a copied description. A `recut` and a
    # `description` on one entry is refused: a text has one source. The
    # canonical must be one the tables spell plainly (`presets.plain`) —
    # that is how an application knows which catalog entry the alias
    # re-spells and withholds an alias whose tool the catalog lacks. No
    # NAME rule lives here (the kernel's `alias_name_reserved` is the one
    # implementation; the harness renders every gem row through it).
    module AliasSpec
      KEYS = %w[name canonical params omit description recut].freeze
      REQUIRED = %w[name canonical].freeze
      PARAM_KEYS = %w[maps_to invert description].freeze
      RECUT_KEYS = %w[anchor replacement].freeze

      module_function

      def read(check, value, path, plain:)
        spec = check.mapping(value, path, required: REQUIRED, optional: KEYS - REQUIRED)
        check.string(spec["name"], "#{path}.name")
        check.one_of(spec["canonical"], "#{path}.canonical", plain.keys)
        params(check, spec["params"], "#{path}.params") if spec.key?("params")
        check.strings(spec["omit"], "#{path}.omit") if spec.key?("omit")
        check.string(spec["description"], "#{path}.description") if spec.key?("description")
        recut(check, spec["recut"], "#{path}.recut") if spec.key?("recut")
        check.refuse(path, "a description and a recut on one entry") if spec.key?("description") && spec.key?("recut")
        spec
      end

      def params(check, value, path)
        check.refuse(path, "expected a mapping, got #{value.class}") unless value.is_a?(Hash)
        value.each do |param, map|
          check.string(param, path)
          check.mapping(map, "#{path}.#{param}", required: ["maps_to"], optional: PARAM_KEYS - ["maps_to"])
          check.string(map["maps_to"], "#{path}.#{param}.maps_to")
          check.boolean(map["invert"], "#{path}.#{param}.invert") if map.key?("invert")
          check.string(map["description"], "#{path}.#{param}.description") if map.key?("description")
        end
      end

      def recut(check, value, path)
        check.mapping(value, path, required: RECUT_KEYS)
        RECUT_KEYS.each { |key| check.string(value[key], "#{path}.#{key}") }
      end
    end
  end
end
