module Rho
  class Runner
    module Extensions
      # THE HANDLE AN EXTENSION RECEIVES — pi's `pi` object, in the
      # vocabulary this side of the boundary actually has.
      #
      # This is the RUNNER's half: tools, and the two hooks that wrap
      # their execution. A daemon composing extensions passes a SUBCLASS
      # that adds its own verbs (commands, lifecycle, UI), so one
      # `register(api)` written by an extension author works under both
      # hosts and never branches on which one it got. That subclassing is
      # the whole mechanism — Ruby supplies it, so there is no capability
      # negotiation to build.
      #
      # A STANDALONE RUNNER ANSWERS THE DAEMON'S VERBS WITH A LOG LINE,
      # not an exception. A runner on a second machine with no daemon in
      # the process is a supported deployment, and an extension that
      # registers a command there has not done anything wrong — its
      # command simply has nobody to surface it.
      #
      # IT IS A STAGING BUFFER. Registrations land here and are committed
      # by the loader only if the factory RETURNED; one that raised
      # half-way through leaves nothing behind. After commit the handle is
      # frozen, so a factory that stashed it and kept registering later
      # gets a FrozenError instead of silently mutating a live runner.
      class Api
        # A provider's block and the ADDRESS it speaks for: an environment
        # description is the runner's (the root's document rides beside
        # the environment tools alone); a document list or a document
        # loader names its address, because an http MCP server's prompts
        # ride the agent row.
        Description = Data.define(:extension, :handler, :serves, :owner) do
          def initialize(owner: nil, **) = super
        end
        # A tool and the ADDRESS it is served on:
        # `:runner` — the environment tools, announced on the runner
        # address; `:agent` — the agent's own (the delegate summarizer),
        # announced on the agent-application address. A standalone runner
        # hosts the first kind alone.
        Registration = Data.define(:klass, :serves, :name, :validator) do
          def initialize(name: nil, **) = super
        end
        SERVES = %i[runner agent].freeze

        # THE HOST'S OWN LIFETIME, registered here on BOTH hosts. A daemon
        # fires these; a standalone runner has no lifetime to speak of and
        # fires nothing — but an extension holding a browser or a child
        # process must still be able to SAY it wants to let go, and until
        # this lived here a runner answered `on(:shutdown)` with an
        # unknown-event error, so the extension failed to load at all. A
        # registration a host does not fire is the same non-answer as a
        # command a host does not surface.
        LIFECYCLE_EVENTS = %i[startup shutdown].freeze
        # THE DAEMON'S OWN EVENTS, answered like its verbs: an extension that
        # shapes a turn, or holds a child per conversation and lets it go
        # when the conversation ends (`:host_ended`),
        # still LOADS here, and a standalone runner — which opens no
        # conversation and follows none — has nothing to fire.
        DAEMON_EVENTS = %i[turn_author turn_follow turn_settled host_ended configuration_change].freeze

        attr_reader :extension_name, :source, :tools, :hooks, :lifecycle,
          :environment_descriptions, :document_descriptions, :document_loaders, :resources, :configuration
        # THE HOST'S LOGGER, for an extension whose failures happen when no
        # call is in flight — a reaper that stops a browser, a driver that
        # dies idle. A tool answers its caller; a thread has nobody to
        # answer, and without this its only channel was silence.
        attr_reader :log
        # THE HOST'S LIFETIME INFRASTRUCTURE (a daemon's home, log, clock,
        # settings, process table), for an extension to close over at
        # register time. nil under a standalone runner, which has none.
        attr_reader :host
        # WHAT THE HOST ANNOUNCES ALREADY on each address when this
        # extension registers: the kernel-shaped entries (`Registry::Entry#
        # announcement`) of every extension committed before it, in load
        # order — the built-ins first — keyed by address, a frozen
        # snapshot. For a tool source that must budget its bytes against
        # the kernel's announcement bound before it registers (rho-mcp,
        # per server): an address's announcement is one PUT the kernel
        # refuses whole, and the host's own tools must announce whatever
        # a third party's list weighs. What loads after this extension is
        # not in it.
        attr_reader :announced

        def initialize(extension_name:, source:, log: nil, host: nil, announced: nil, configuration: {}, tool_suffix: nil)
          @extension_name = extension_name.to_s
          @source = source.to_s
          @log = log
          @host = host
          @configuration = configuration
          @tool_suffix = tool_suffix
          @announced = SERVES.to_h { |serves| [serves, Array(announced&.dig(serves)).freeze] }.freeze
          @tools = []
          @hooks = []
          @lifecycle = []
          @environment_descriptions = []
          @document_descriptions = []
          @document_loaders = []
          @resources = Resources.new(extension: @extension_name, log: log)
          @restart_only = false
          @status = nil
        end

        # Status reads project known state; callbacks must not connect or run work.
        def describe_status(&block)
          raise RegistrationError, "describe_status needs a block" unless block

          @status = block
        end

        def readiness = @status ? @status.call : { ready: true, issues: [] }

        # An integration with one exclusive process-wide resource cannot prepare
        # a second independent instance while the first is still in service.
        def restart_only
          @restart_only = true
          self
        end

        def restart_only? = @restart_only

        # Managed source versions use distinct served names. An accepted call
        # never resolves the previous version's name to a replacement body.
        def tool_name(name)
          value = @tool_suffix ? "#{name}_#{@tool_suffix}" : name.to_s
          unless Tool::NAME_FORMAT.match?(value)
            raise RegistrationError, "#{@extension_name} has an invalid served tool name #{value.inspect}"
          end
          value
        end

        # THE PROMISE IN THE HEADER, KEPT. `Object#freeze` is shallow, so a
        # frozen handle with live arrays inside still accepted a late
        # `register_tool` or `on` without a word — and the registry had
        # already copied what it wanted, so the late registration was
        # dropped rather than refused, which is the exact failure the
        # header says cannot happen. Freezing the collections is what
        # makes it a FrozenError.
        def freeze
          @tools.freeze
          @hooks.freeze
          @lifecycle.freeze
          @environment_descriptions.freeze
          @document_descriptions.freeze
          @document_loaders.freeze
          super
        end

        # WHICH ADDRESS THIS HOST SERVES: the base handle — a
        # runner with no daemon in the process — hosts runner tools alone;
        # a daemon's subclass answers by its mode. An extension whose tools
        # are one address's and whose verbs are every host's (the process
        # table's person-facing doors) asks here instead of registering a
        # tool the host would refuse.
        def serves?(source) = source == :runner

        # A tool CLASS, never an instance: the host builds one per toolset
        # and binds the execution environment, because a tool that arrived
        # already constructed would have closed over somebody else's.
        # `serves:` names the address (see Registration); the base handle —
        # a runner with no daemon in the process — refuses an agent tool
        # by name rather than serving one that would fail every call.
        def register_tool(klass, serves: :runner)
          unless SERVES.include?(serves)
            raise RegistrationError, "#{@extension_name} registers #{klass}: serves must be :runner or :agent, " \
              "not #{serves.inspect}"
          end
          if serves == :agent
            raise RegistrationError,
              "#{@extension_name} registers #{klass} with serves: :agent; a standalone runner hosts no agent " \
              "tool — register it under a daemon (serves: :agent) or as a runner tool"
          end

          validator = Tool.validate(klass, extension: @extension_name)
          @tools << Registration.new(klass: klass, serves: serves, name: tool_name(klass::NAME), validator: validator)
          self
        end

        # WHAT MY TOOLS ARE BOUND TO, in my own words. Handed the
        # environment, answers text or nil.
        #
        # CALLED ONCE, AT AUTHORING — never per round and never per call —
        # because the bytes it returns sit at the front of a cached prefix
        # for the life of a loop. A description that changed between
        # rounds would move that prefix every round.
        #
        # NOTHING IT SAYS CONSTRAINS ANYTHING. The environment is a
        # statement of what happens to be known, not a boundary: a path
        # outside all of it still works, because these tools decline path
        # confinement on purpose. So a provider that knows nothing worth
        # saying answers nil, and that is an ordinary answer.
        def describe_environment(&handler)
          raise RegistrationError, "describe_environment needs a block" if handler.nil?

          @environment_descriptions << Description.new(
            extension: @extension_name, handler: handler, serves: :runner, owner: @resources
          )
          self
        end

        # WHAT MY TOOLS CAN LOAD FOR A MODEL: the
        # documents this address announces beside its tools — a checkout's
        # skills, as the Coding extension scans them; an MCP server's
        # prompts and resources, as rho-mcp curates them — handed the
        # environment, answering a list of `{name, description}` entries
        # (the kernel's skill grammar: the name lowercase alphanumerics and
        # single hyphens, the description a non-empty string ≤ 1024 bytes)
        # or nothing. Read at announcement — at placement and on `rho env`
        # — never per round: the kernel renders the list into the turn's
        # catalog itself. A provider that raises costs its own list and
        # never the announcement (`Registry#documents`); a load of a name
        # announced here is addressed to this ADDRESS's `skill` tool.
        # `serves:` names the address: the runner's by
        # default — Coding's — or the agent's, where an http MCP server's
        # documents ride; an extension that announces documents on an
        # address must serve `skill` there (Coding does on the runner's;
        # rho-mcp does on the agent's). A host that does not serve the
        # address refuses the registration by name, as `register_tool` does.
        def describe_documents(serves: :runner, &handler)
          raise RegistrationError, "describe_documents needs a block" if handler.nil?

          refuse_unserved!("describe_documents", serves)
          @document_descriptions << Description.new(
            extension: @extension_name, handler: handler, serves: serves, owner: @resources
          )
          self
        end

        # HOW A DOCUMENT I ANNOUNCED IS LOADED: the
        # address's `skill` tool walks its loaders in registration order
        # (`Registry#load_document`), handing each `(name, env)` — the
        # document's announced name and the tool's execution environment
        # (root, artifacts directory: a loader that captures a file writes
        # it there) — and the first `Result` wins; nil says "not mine" and
        # falls through, a raise costs that loader and never the load, and
        # a name no loader holds answers `skill_unknown`. The body a loader
        # answers is the `Result` the row commits — `Result.ok(text)`, or
        # `Result.error("skill_unavailable: …")` for a document the loader
        # holds and cannot serve.
        def load_document(serves: :runner, &handler)
          raise RegistrationError, "load_document needs a block" if handler.nil?

          refuse_unserved!("load_document", serves)
          @document_loaders << Description.new(
            extension: @extension_name, handler: handler, serves: serves, owner: @resources
          )
          self
        end

        # `tool_call` runs BEFORE a handler and may veto or rewrite the
        # arguments; `tool_result` runs after and may rewrite the answer.
        # They are the pair every comparable system converges on, and the
        # only two events that are executor-local by the normative rule —
        # everything about the conversation belongs to the kernel. Command
        # hooks are EXTENSION-ONLY: this block is
        # the one hook door; there is no config-file hook door.
        def on(event, &handler)
          raise RegistrationError, "on(#{event.inspect}) needs a block" if handler.nil?
          return unavailable("hook #{event}") if DAEMON_EVENTS.include?(event)

          registration = Hooks::Registration.new(
            event: event, extension: @extension_name, handler: handler, owner: @resources
          )
          if Hooks::EVENTS.include?(event)
            @hooks << registration
          elsif LIFECYCLE_EVENTS.include?(event)
            @lifecycle << registration
            @resources.own(&handler) if event == :shutdown
          else
            offered = (Hooks::EVENTS + LIFECYCLE_EVENTS).join(", ")
            raise RegistrationError, "unknown event #{event.inspect}; this host offers #{offered}"
          end
          self
        end

        # The daemon-only verbs, answered here so an extension written for
        # a daemon still LOADS in a standalone runner. Overridden by the
        # daemon's subclass; never raising is the point.
        def register_command(name, **, &)
          unavailable("command #{name}")
        end

        def background(name = @extension_name, &)
          unavailable("background task #{name}")
        end

        def register_route(method, path, **, &)
          unavailable("route #{method} #{path}")
        end

        def register_webui(root:)
          unavailable("webui")
        end

        def register_flags(command, **, &)
          unavailable("flags on #{command}")
        end

        # The editor's MCP servers per conversation are a DAEMON's to serve: a standalone runner follows no
        # conversation and has no agent slot to serve them on.
        def register_conversation_servers(&)
          unavailable("conversation servers")
        end

        private

          # `serves:` is validated against SERVES and refused where this
          # host serves no such address (`serves?`): the base handle — a
          # runner with no daemon in the process — hosts the runner's
          # alone; a daemon's answers by its mode.
          def refuse_unserved!(verb, serves)
            unless SERVES.include?(serves)
              raise RegistrationError, "#{@extension_name} calls #{verb}: serves must be :runner or :agent, " \
                "not #{serves.inspect}"
            end
            return if serves?(serves)

            raise RegistrationError,
              "#{@extension_name} calls #{verb} with serves: #{serves.inspect}; this host serves no #{serves} " \
              "address — a standalone runner hosts the runner's alone, a daemon what its mode serves"
          end

          def unavailable(what)
            @log&.info("extension_verb_unavailable",
              extension: @extension_name, detail: "#{what} is not surfaced by a standalone runner")
            self
          end
      end
    end
  end
end
