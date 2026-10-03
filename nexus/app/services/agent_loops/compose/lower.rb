module AgentLoops
  module Compose
    # A built script is a step tree in the door's own vocabulary, so this
    # stage adds only what the isolate cannot know: the call's namespace on
    # every key, the round's tools behind each name, and the inherited surface.
    class Lower
      # A key the model reads back in refusals and in the transcript. The
      # namespace and a separator have to fit beside it.
      MAX_SCRIPT_KEY = 32

      Result = Data.define(:steps, :keys, :refusal, :detail) do
        class << self
          def lowered(steps, keys) = new(steps:, keys:, refusal: nil, detail: nil)
          def refused(code, detail = nil) = new(steps: [], keys: [], refusal: code, detail:)
        end

        def lowered? = refusal.nil?
      end

      class RefusalError < StandardError
        attr_reader :code, :detail

        def initialize(code, detail)
          @code = code
          @detail = detail
          super("#{code}: #{detail}")
        end
      end

      class << self
        def call(...) = new(...).call
        def stage(**options) = new(**options, stage: true).call

        # A compiler refusal is positional and the model wrote lines, so
        # each is handed back with its script key and line.
        def explain(errors, built)
          Array(errors).map do |error|
            located = locate(built, error["path"].to_s)
            next error.except("path") if located.nil?

            error.except("path").merge("step" => located[:key], "line" => located[:line]).compact
          end
        end

        private

          # `steps[1].parallel[0][2].prompt` walks the step tree and the line
          # tree together: `.parallel[j]` descends into a group, `[k]` into a
          # nested sequence.
          def locate(built, path)
            match = path.match(/\Asteps\[(\d+)\]/) or return nil
            step = built.steps[match[1].to_i]
            line = built.lines[match[1].to_i]
            path.delete_prefix(match[0]).scan(/\.parallel\[(\d+)\]|\[(\d+)\]/).each do |group, nested|
              index = (group || nested).to_i
              step = group ? Array(step["parallel"])[index] : Array(step)[index]
              line = group ? Array(Hash.try_convert(line)&.fetch("members", nil))[index] : Array(line)[index]
              return nil if step.nil?
            end
            { key: script_key(step), line: Hash.try_convert(line)&.fetch("line", nil) || line }
          end

          def script_key(step)
            body = Hash.try_convert(step) or return nil
            verb = (body.keys & Tasks::Step::VERBS).first
            return nil if verb.nil? || verb == "parallel"

            Hash.try_convert(body[verb])&.fetch("key", nil)
          end
      end

      def initialize(built:, node:, lifetime: node.lifetime, wake: node.wake, model_defaults: nil, stage: false)
        @built = built
        @node = node
        @namespace = node.node_key unless stage
        round = KernelTool.round_of(node) unless stage
        @defaults = model_defaults || Tasks::Step.model_defaults(round)
        @visibility = round&.transcript_visibility
        @model_authored = !stage || node.authored_by == "model"
        @lifetime = lifetime
        @wake = wake
        @keys = []
      end

      def call
        steps = @built.steps.map { |step| lower(step) }
        Result.lowered(steps, @keys)
      rescue RefusalError => error
        Result.refused(error.code, error.detail)
      end

      private

        def refuse(code, detail) = raise(RefusalError.new(code, detail))

        def lower(step)
          fields = Hash.try_convert(step) or refuse(:script_error, "a step must be an object")
          verb = (fields.keys & Tasks::Step::VERBS).first or
            refuse(:script_error, "not a step: #{fields.keys.join(", ")}")
          send(:"lower_#{verb}", fields.fetch(verb), fields)
        end

        # Every model-authored task absorbs its own failure: the round reads
        # an error envelope, never a stranded deliverable. No step carries a
        # WHEN word: the subgraph's detachment rides the tip the call hands
        # in, so every step is placed `detached: false`.
        def lower_tool(body, _fields)
          name = body["name"].to_s
          if @model_authored
            refuse(:unknown_tool_name, not_a_tool("g.tool", name)) unless declared_names.include?(name)
          elsif Nexus::ToolRegistry.kernel_name?(name)
            refuse(:reserved_tool_name, "g.tool: #{name.inspect} is reserved for model tool calls")
          end

          Tasks::Step::Tool.new(
            key: namespaced(body["key"]), name: name, input: body["input"] || {},
            timeout_ms: body["timeout_ms"], on_failure: ("absorb" if @model_authored),
            after: references(body, "after")
          )
        end

        def lower_model(body, _fields)
          fields = @defaults.merge(
            "key" => namespaced(body["key"]), "prompt" => body["prompt"], "tools" => narrowed_tools(body["tools"]),
            "lifetime" => @lifetime, "wake" => @wake, "after" => references(body, "after"), "results" => references(body, "results")
          ).merge(body.slice("model", "instructions"))
          fields["visibility"] = @visibility if @visibility
          fields["on_failure"] = "absorb" if @model_authored
          Tasks::Step.from_h({ "model" => fields }, "model")
        end

        def lower_ask(body, _fields)
          Tasks::Step::Ask.new(
            key: namespaced(body["key"]), prompt: body["prompt"], timeout_ms: body["timeout_ms"],
            options: body["options"], multi: body["multi"], after: references(body, "after")
          )
        end

        # The observed identity comes from an earlier launch receipt. Only
        # this new wait's key and local dependencies enter the call's namespace.
        def lower_wait(body, _fields)
          Tasks::Step::Wait.new(
            key: namespaced(body["key"]), task: body["task"], agent_loop: body["agent_loop"],
            timeout_ms: body["timeout_ms"], after: references(body, "after")
          )
        end

        def lower_script(body, _fields)
          Tasks::Step::Script.new(
            key: namespaced(body["key"]), script: body["script"], params: body["params"] || {},
            model_defaults: @defaults.merge("tools" => narrowed_tools(nil)),
            after: references(body, "after"), results: references(body, "results"),
            on_failure: ("absorb" if @model_authored)
          )
        end

        # A model's race cancels its losers and absorbs its own starvation:
        # the follower runs and reads that nothing won. Its key is the one
        # the builder minted — the name a later step's `after`/`results`
        # already carries — so a race that arrives without one is the
        # builder's defect and fails loud.
        def lower_parallel(members, fields)
          lowered = Array(members).map do |member|
            sequence = Array.try_convert(member)
            sequence ? sequence.map { |step| lower(step) } : lower(member)
          end
          racing = !fields["until"].nil? && fields["until"] != "all"
          Tasks::Step::Parallel.new(
            members: lowered, until: fields["until"],
            key: (namespaced(fields.fetch("key")) if racing),
            on_failure: ("absorb" if racing && @model_authored)
          )
        end

        # The builder hands out every key, so the rewrite is total and a
        # composed task can never name one outside its subgraph.
        def namespaced(key)
          full_key(key).tap { |full| @keys << full }
        end

        def full_key(key)
          key = key.to_s
          if key.length > MAX_SCRIPT_KEY
            refuse(:composed_key_too_long, "#{key.first(MAX_SCRIPT_KEY)}… (max #{MAX_SCRIPT_KEY} characters)")
          end

          @namespace ? "#{@namespace}-#{key}" : key
        end

        def references(body, field) = body[field]&.map { |key| full_key(key) }

        def declared_names = @declared_names ||= Nexus::ToolDeclarations.names(@defaults["tools"])

        def not_a_tool(verb, name)
          "#{verb}: #{name.inspect} is not one of your tools. You have: #{declared_names.join(", ")}"
        end

        # The round's tools minus its graph verbs, narrowed by name when the
        # script names fewer; a name the round never declared is refused.
        def narrowed_tools(names)
          wanted = names.nil? ? nil : (Array.try_convert(names) or
            refuse(:script_error, "g.model: tools must name your tools, e.g. tools: [\"read\"]"))
          narrowed = BranchTools.narrow_definitions(@defaults["tools"], wanted)
          refuse(:unknown_tool_name, not_a_tool("g.model", narrowed.refused)) if narrowed.refused

          narrowed.definitions
        end
    end
  end
end
