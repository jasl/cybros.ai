module Rho
  class Runner
    module Extensions
      # WHAT THIS RUNNER CAN DO, assembled rather than frozen into a
      # constant — the seam `Toolset`'s own comment predicted: "when an
      # extension plane arrives, this is the seam it replaces."
      #
      # THE BUILT-INS COME THROUGH THE SAME DOOR. That is the whole point
      # of the plane and the predecessor's own rule: if the seven had a
      # privileged path, the path a third party uses would be the one
      # nobody tests.
      #
      # A COLLISION IS A LOAD ERROR, not a silent winner. `BUILT_IN.to_h`
      # took the last registration of a duplicated name and said nothing,
      # so two extensions claiming `bash` produced a runner that served
      # one of them by load order. There is no override chain to replace
      # it with: an extension that wants to replace `bash` registers a
      # different name and the operator disables the built-in — which is a
      # decision somebody made, rather than one that happened.
      #
      # ENTRIES ARE KEYED PER ADDRESS — `[serves, name]`: the collision rule is one address's, so the plane's `skill`
      # is served on the runner address by Coding and on the agent address
      # by an extension announcing documents there (rho-mcp, for an http
      # server's prompts), and `serving(source)` narrows by the key. The
      # document lists and the document LOADERS carry their address the
      # same way; the environment description is the runner's alone.
      class Registry
        # `validator` is the tool's `SCHEMA` compiled ONCE, at registration: every
        # placement's toolset (`Toolsets`) hands the same compiled schema to
        # its `Toolset::Tool`, so a second root costs no schema parse per
        # tool — and a call is checked against it before the handler runs.
        Entry = Data.define(:name, :klass, :extension, :source, :serves, :validator, :owner) do
          def initialize(owner: nil, **) = super

          def description = klass::DESCRIPTION
          def schema = klass::SCHEMA
          def effect_profile = klass::EFFECT_PROFILE
          # nil when the tool declares none: the kernel's default park.
          def timeout_ms = Tool.timeout_ms(klass)
          # Served, described to nobody: an announcement omits this entry's
          # `description` and `input_schema`.
          def undescribed? = Tool.undescribed?(klass)

          # The MCP `Tool` shape, which is what a declaration looks like
          # everywhere this project touches one — and the INPUT to the
          # SDK's lowering, never something spliced onto a provider wire.
          def declaration
            { "name" => name, "description" => description, "inputSchema" => schema }
          end

          # THE ANNOUNCEMENT'S ENTRY: the name and
          # `effect_profile` (the kernel freezes it on each row it
          # addresses here, and the sweep reads it at expiry), the
          # declaration facts a remote agent authors a declaration from
          # (`description`, the kernel's `input_schema` spelling of the MCP
          # `inputSchema`), and `timeout_ms` only where the tool declares a
          # park of its own. An entry described to nobody announces its
          # name, profile and park alone: served, never authorable by a
          # peer. ONE renderer for every announcer — the registry's list
          # below, and a tool source budgeting one entry's kernel bytes
          # before it registers (rho-mcp).
          def announcement = Tool.announcement(klass, name: name)
        end

        def initialize(log: nil)
          @entries = {}
          @hooks = []
          @descriptions = []
          @documents = []
          @loaders = []
          @log = log
        end

        # A collision anywhere in the handle rejects its whole declaration,
        # so no tool can be published without the hooks registered beside it.
        def commit(api)
          entries = {}
          api.tools.each do |registration|
            klass = registration.klass
            name = registration.name || klass::NAME.to_s
            key = [registration.serves, name]
            existing = entries[key] || @entries[key]
            if existing
              raise RegistrationError,
                "#{api.extension_name} registers #{name.inspect} on the #{registration.serves} address, already " \
                "registered there by #{existing.extension} (#{existing.source}). Two extensions cannot serve one " \
                "name on one address — register a different one and disable the other."
            end

            entries[key] = Entry.new(
              name: name, klass: klass, extension: api.extension_name, source: api.source,
              serves: registration.serves, validator: registration.validator, owner: api.resources
            )
          end
          @entries.merge!(entries)
          @hooks.concat(api.hooks)
          @descriptions.concat(api.environment_descriptions)
          @documents.concat(api.document_descriptions)
          @loaders.concat(api.document_loaders)
          self
        end

        # THE ADDRESS'S OWN VIEW: the entries served on one
        # address, under the SAME hook chain (a guard's veto applies wherever
        # the tool runs), with the environment descriptions the runner
        # address's alone — the environment document rides beside the
        # environment tools, never beside the agent's own — and the document
        # lists and loaders the address's own.
        def serving(source)
          narrowed = Registry.new(log: @log)
          narrowed.adopt(
            @entries.select { |(serves, _), _| serves == source }, @hooks,
            source == :runner ? @descriptions : [],
            @documents.select { |registration| registration.serves == source },
            @loaders.select { |registration| registration.serves == source }
          )
        end

        # The names served, in commit order; a name served on both addresses
        # (the plane's `skill` under a full-mode daemon hosting an http MCP
        # server's documents) is listed once per address.
        def names = @entries.each_value.map(&:name)

        def entries = @entries.values

        def extension_names = @entries.each_value.map(&:extension).uniq

        # The MCP declarations a task author lowers and sends. This is the
        # reader `Toolset#declarations` never had.
        def declarations = @entries.each_value.map(&:declaration)

        # THE FRAGMENTS EVERY BUILT-IN HAS DECLARED AND NOTHING HAS READ.
        # A host assembling a model task's instructions builds its
        # "Available tools" section from these; a tool that declares no
        # snippet is omitted from that section rather than described badly.
        def prompt_fragments
          @entries.each_value.filter_map do |entry|
            snippet = Tool.prompt_snippet(entry.klass)
            next if snippet.nil? || snippet.to_s.empty?

            { "name" => entry.name, "snippet" => snippet.to_s,
              "guidelines" => Tool.prompt_guidelines(entry.klass) }
          end
        end

        # WHAT EACH PROVIDER SAYS ABOUT THE ENVIRONMENT ITS TOOLS ARE
        # BOUND TO. FAIL-OPEN, one provider at a time: a description that
        # raises — a filesystem read that failed, a git that is not
        # installed — costs that provider its paragraph and never the
        # authoring. Losing the whole block because one contributor
        # stumbled would be an observer that destroys.
        def environment_fragments(environment)
          @descriptions.filter_map do |registration|
            text = describe(registration, environment)
            next if text.nil? || text.to_s.strip.empty?

            { "extension" => registration.extension, "text" => text.to_s }
          end
        end

        # WHAT EACH PROVIDER SAYS IT CAN LOAD FOR A MODEL: every provider's `{name, description}` entries in registration
        # order, the announcement's `documents` list. FAIL-OPEN, one provider
        # at a time, as the environment fragments are: a scan that raises — a
        # directory that vanished, a file that cannot be read — costs that
        # provider its list and never the announcement. A provider answering
        # nil or nothing contributes nothing. A NAME MET TWICE — across
        # providers or within one provider's own list — keeps the first and
        # logs (a checkout skill and an MCP prompt that fold to one name):
        # the kernel's door refuses a repeated name for the WHOLE
        # announcement, which would cost every tool on the address.
        def documents(environment)
          seen = {}
          @documents.flat_map do |registration|
            Array(describe(registration, environment)).select do |entry|
              name = Hash.try_convert(entry)&.dig("name")
              next true if name.nil?

              announced_by = seen[name]
              if announced_by
                @log&.warn("extension_document_repeated", extension: registration.extension, name: name,
                  announced_by: announced_by)
                false
              else
                seen[name] = registration.extension
                true
              end
            end
          end
        end

        # THE LOAD OF A DOCUMENT THIS ADDRESS ANNOUNCED: the address's loaders in registration order, each handed
        # `(name, env)`; the first `Result` wins, nil falls through, and a
        # loader that raises costs itself and never the load — the
        # environment fragments' own fail-open rule. nil when no loader
        # holds the name: the `skill` tool answers `skill_unknown`.
        def load_document(name, env)
          @loaders.each do |registration|
            result = load(registration, name, env)
            return result unless result.nil?
          end
          nil
        end

        # The first entry of that name on any address: the profile is the
        # class's, the same wherever it is served.
        def effect_profile(name) = @entries.each_value.find { |entry| entry.name == name.to_s }&.effect_profile

        # THE ANNOUNCEMENT: what this registry SERVES,
        # for `executor.announce(tools:)` — every entry's `Entry#announcement`,
        # sorted by name. ONE renderer for every announcer — rho's daemon
        # and the harness executor render one shape (moved down from rho's `RunDeclaration.announcement`, which delegates here; the bytes are pinned identical).
        def announcement
          @entries.each_value.map(&:announcement).sort_by { |entry| entry.fetch("name") }
        end

        def hooks = Hooks::Host.new(@hooks, log: @log)

        # THE ONLY WAY TO GET AN EXECUTABLE TOOLSET. One instance per tool
        # per toolset, shared by every worker thread — which is why a tool
        # keeps no mutable instance state, and why that sentence belongs in
        # the contract rather than in somebody's bug report. A toolset is
        # ONE ADDRESS's (a daemon builds each slot's from `serving`); over a
        # registry holding a name on both addresses the runner's instance
        # is the one built, so a whole-registry toolset reads as the
        # standalone runner's.
        def toolset(env:)
          runner, agent = @entries.values.partition { |entry| entry.serves == :runner }
          Toolset.new((agent + runner).to_h { |entry| [entry.name, tool_for(entry, env)] })
        end

        protected

          def adopt(entries, hooks, descriptions, documents, loaders)
            @entries = entries
            @hooks = hooks
            @descriptions = descriptions
            @documents = documents
            @loaders = loaders
            self
          end

        private

          def describe(registration, environment)
            invoke(registration, environment)
          rescue StandardError => error
            @log&.warn("extension_description_failed", extension: registration.extension,
              error_class: error.class.name)
            nil
          end

          def load(registration, name, env)
            invoke(registration, name, env)
          rescue StandardError => error
            @log&.warn("extension_document_load_failed", extension: registration.extension, name: name,
              error_class: error.class.name)
            nil
          end

          # A provider may own a connection even when a different extension
          # supplies the address's shared skill tool.
          def invoke(registration, *arguments)
            owner = registration.owner&.acquire
            registration.handler.call(*arguments)
          ensure
            owner&.release
          end

          # The plane's own `skill` is the one tool with a second
          # constructor argument: its address's loader walk.
          def tool_for(entry, env)
            instance = entry.klass == Tools::Skill ? entry.klass.new(env: env, loaders: method(:load_document)) : entry.klass.new(env: env)
            Toolset::Tool.new(
              name: entry.name, description: entry.description, parameters: entry.schema, validator: entry.validator,
              timeout_ms: entry.timeout_ms, internal_clamp: Tool.internal_clamp?(entry.klass),
              effect_profile: entry.effect_profile,
              owner: entry.owner,
              # The context is bound by the pool on the worker thread, so a
              # handler reads it through `ExecutionContext.current` rather
              # than from this argument.
              handler: ->(args, _context) { instance.call(args) }
            )
          end
      end
    end
  end
end
