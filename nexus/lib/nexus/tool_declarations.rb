module Nexus
  # The rules one declared tool set obeys wherever it is authored — on a
  # model task or on an Agent Profile — so a set the profile accepts is a
  # set every round accepts.
  #
  # THREE KINDS OF ENTRY: a runner's tool (any bytes); a
  # kernel tool in the catalog's exact bytes; and an ALIAS of a kernel
  # tool — `{name, canonical, params?, omit?, description?}`, the declaring
  # agent's own SPELLING of a kernel tool (`Agent` for `nexus.graph.task`).
  # The canonical stays the kernel's: routing, the reserved namespaces and
  # the override rules never see an alias. A call arrives under the alias
  # and runs under the kernel's wire name (`resolve_call`, read at the one
  # site a model's call becomes a row); the store holds the set's RENDER
  # (`render`); a provider sees the function blocks alone (`wire`).
  module ToolDeclarations
    # The alias name's bounds: the node column that keeps it is string(128).
    ALIAS_NAME_MAX_LENGTH = 128

    class << self
      # A non-empty list of declarations. An empty array is a typo'd intent
      # on a task and "none" on a profile; the caller decides which.
      def entries?(value)
        entries = Array.try_convert(value)
        !entries.nil? && !entries.empty? && entries.none? { |entry| Hash.try_convert(entry).nil? }
      end

      # An entry carrying `canonical` is an alias.
      def alias?(entry)
        hash = Hash.try_convert(entry)
        !hash.nil? && hash.key?("canonical")
      end

      # The kernel canonical an entry names — an alias's `canonical`, else
      # the entry's name resolved in either spelling — or nil for a
      # runner's tool.
      def canonical_of(entry)
        hash = Hash.try_convert(entry) or return nil
        Nexus::ToolRegistry.resolve(alias?(hash) ? hash["canonical"] : name_of(hash))
      end

      # THE DECLARATION-TIME REFUSAL, one word or nil. Declaring a kernel
      # tool is how an agent turns it on: a live name in other bytes than
      # the set's render tells the model one thing while the kernel does
      # another (`kernel_tool_redefined`). Two entries on one name are
      # `duplicate_tool_name`; the alias grammar's own words follow
      # (`alias_refusal`).
      def refusal(entries)
        declared = names(entries)
        return "duplicate_tool_name" if declared.length != declared.uniq.length

        entries.each do |entry|
          hash = Hash.try_convert(entry) || {}
          word = alias?(hash) ? alias_refusal(hash, entries) : kernel_name_refusal(hash, entries)
          return word if word
        end
        nil
      end

      # The stored form: the set rendered with its own spellings
      # (`Render`). A set the grammar refuses is returned as given, so the
      # validator names the refusal on the bytes the author sent.
      def render(entries)
        return entries unless refusal(entries).nil?

        Render.render(entries)
      end

      # The provider-bound set: an alias's resolution facts never reach a
      # provider (the OpenAI-compatible protocol would pass them through).
      # An omitted strict setting means optional schema fields stay optional:
      # Responses otherwise attempts strict normalization and can require them.
      # Both declaration shapes share this default; explicit choices survive.
      def wire(entries)
        Array(entries).map do |entry|
          definition = alias?(entry) ? entry.slice("type", "function") : entry
          function = definition["function"] || definition
          if definition["type"] == "function" && !function.key?("strict") && !definition.key?("strict")
            function = function.merge("strict" => false)
            definition["function"] ? definition.merge("function" => function) : function
          else
            definition
          end
        end
      end

      # THE ONE RESOLUTION SITE'S READ: `[wire_name, input, alias]`. For a
      # declared alias the kernel's wire name, the input with each mapped
      # key moved to the kernel's word (negated when the map inverts and
      # the value is a boolean — a non-boolean moves as is, and the
      # kernel's own refusal names the kernel word, a recorded residue),
      # each omitted key dropped, every other key through; and the alias
      # the model spelled. For anything else the call as given.
      def resolve_call(entries, name, input)
        name = name.to_s
        entry = Array(entries).find { |candidate| alias?(candidate) && name_of(candidate) == name }
        return [name, input, nil] if entry.nil?

        tool = Nexus::ToolRegistry.entry(entry["canonical"])
        params = Hash.try_convert(entry["params"]) || {}
        input = Hash.try_convert(input) || {}
        mapped = input.except(*params.keys, *Array(entry["omit"]))
        params.each do |alias_param, spec|
          next unless input.key?(alias_param)

          value = input[alias_param]
          value = !value if spec["invert"] && [true, false].include?(value)
          mapped = mapped.merge(spec["maps_to"] => value)
        end
        [tool.name, mapped, name]
      end

      # A tool list is a set at the front of every cached prefix, so it is
      # canonicalized by name or a re-ordered re-authoring busts the cache
      # (opencode sorts, claude-code latches, codex pins it).
      def canonical(entries)
        entries.sort_by { |entry| sort_key(entry) }
      end

      # Both spellings: a declaration nests the name under `function` or
      # carries it flat, and every wire protocol renders both.
      def name_of(definition)
        entry = Hash.try_convert(definition) or return nil
        entry.dig("function", "name") || entry["name"]
      end

      def names(entries) = Array(entries).filter_map { |definition| name_of(definition) }

      # A SUBSET OF AN INHERITED SET, BY NAME — the one implementation a
      # branch (`task({tools})`, `g.model({tools})`) and a turn (the
      # input's `tool_names` onto the materialization seed) share. The
      # declaration's order is kept: the subset is the same bytes, fewer
      # of them, so a prefix cached on the whole set is not re-shuffled.
      # nil wants everything.
      def narrow(entries, wanted)
        return entries if wanted.nil?

        wanted = wanted.map(&:to_s)
        Array(entries).select { |definition| wanted.include?(name_of(definition)) }
      end

      # A continuation can retain only tools its source declared and its
      # current profile still declares. Kernel aliases share their canonical
      # identity; other tools keep their declared name. Return the current
      # spelling, in declaration order, including an explicit empty set.
      def intersection_names(entries, inherited:)
        allowed = Array(inherited).filter_map { |definition| canonical_of(definition) || name_of(definition) }.to_set
        Array(entries).filter_map do |definition|
          name_of(definition) if allowed.include?(canonical_of(definition) || name_of(definition))
        end
      end

      # The first wanted name the set cannot give, or nil: a subset is
      # never an addition, and the caller's refusal names the culprit.
      def undeclared(entries, wanted)
        declared = names(entries)
        wanted.map(&:to_s).find { |name| !declared.include?(name) }
      end

      private

        def sort_key(entry)
          hash = Hash.try_convert(entry) || {}
          function = Hash.try_convert(hash["function"]) || {}
          [(function["name"] || hash["name"]).to_s, entry.to_json]
        end

        # A plain entry whose name is the kernel's: the catalog's bytes, or
        # the set's render of them (what the store holds beside an alias).
        def kernel_name_refusal(hash, entries)
          canonical = Nexus::ToolRegistry.resolve(name_of(hash))
          return nil if canonical.nil?
          return nil if hash == Nexus::ToolRegistry.function_definition(canonical)
          return nil if hash == Render.kernel_entry(canonical, Render.spellings(entries))

          "kernel_tool_redefined"
        end

        # The alias grammar: a live canonical, a name of the agent's own, a
        # parameter map onto the kernel's parameters, and — when a function
        # block rides along — the set's render of it.
        def alias_refusal(hash, entries)
          name = name_of(hash)
          return "invalid" unless alias_name?(name)

          canonical = Nexus::ToolRegistry.resolve(hash["canonical"])
          return "alias_canonical_unknown" unless canonical && Nexus::ToolRegistry.kernel_name?(canonical)
          return "alias_name_reserved" if Nexus::ToolRegistry.kernel_name?(name)
          return "invalid" unless hash["description"].nil? || hash["description"].is_a?(String)

          tool = Nexus::ToolRegistry.entry(canonical)
          word = omit_refusal(hash["omit"], tool) || params_refusal(hash["params"], Array(hash["omit"]), tool)
          word || function_block_refusal(hash, canonical, entries)
        end

        def alias_name?(name)
          name.is_a?(String) && !name.empty? && name.length <= ALIAS_NAME_MAX_LENGTH && !name.include?("\u0000")
        end

        def omit_refusal(omit, tool)
          return nil if omit.nil?
          return "invalid" unless omit.is_a?(Array) && omit.all?(String)

          "alias_param_unknown" unless (omit - tool.parameter_names).empty?
        end

        def params_refusal(params, omit, tool)
          return nil if params.nil?
          return "invalid" unless params.is_a?(Hash) && params.values.all?(Hash)

          targets = params.values.map { |spec| spec["maps_to"] }
          return "alias_param_unknown" unless targets.all?(String) && (targets - tool.parameter_names).empty?
          return "alias_param_unknown" if targets.length != targets.uniq.length || targets.intersect?(omit)

          kept = tool.parameter_names - targets - omit
          return "alias_param_unknown" if params.keys.intersect?(kept)

          params.each_value do |spec|
            word = param_spec_refusal(spec, tool)
            return word if word
          end
          nil
        end

        def param_spec_refusal(spec, tool)
          return "invalid" unless [nil, true, false].include?(spec["invert"])
          return "invalid" unless spec["description"].nil? || spec["description"].is_a?(String)
          return nil unless spec["invert"]

          kernel_type = tool.parameter_template.dig("properties", spec["maps_to"], "type")
          return "alias_invert_needs_boolean" unless kernel_type == "boolean"

          "alias_param_description_required" if spec["description"].nil?
        end

        # `function.name` alone is the compact input spelling; anything
        # more must be the set's own render of this alias.
        def function_block_refusal(hash, canonical, entries)
          function = Hash.try_convert(hash["function"])
          return nil if function.nil? || function.keys == ["name"]

          rendered = Render.function_definition(canonical,
            name: name_of(hash), params: hash["params"], omit: hash["omit"],
            description: hash["description"], spellings: Render.spellings(entries))
          "kernel_tool_redefined" unless function == rendered["function"]
        end
    end
  end
end
