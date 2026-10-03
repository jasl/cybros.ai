module AgentLoops
  module Tasks
    # The one lowering from a step tree to node and edge payloads: every task
    # waits on the tip before it; an authored step reads what its author named
    # (`Nexus::Compose::Reads`); a model step on the loop's own path continues
    # the spine the tip hands it and reads the round's paired calls beside what
    # it names; the tip moves as the steps are written.
    class Compile
      TASK_KEY_FORMAT = AgentLoopNode::NODE_KEY_FORMAT
      MAX_TASKS_PER_REQUEST = 64
      MAX_DEPENDENCIES_PER_TASK = 32
      # The kernel transcribes what a model emitted, and a 40-call fan is
      # ordinary output, so it has its own bounds above the client's request hygiene.
      KERNEL_MAX_TASKS_PER_REQUEST = Nexus::StepBounds::KERNEL_MAX_TASKS_PER_REQUEST
      KERNEL_MAX_DEPENDENCIES_PER_TASK = 256
      # +1 admits a continuation splicing prior model output on top of a
      # full tool fan-in (the predecessor's measured allowance).
      KERNEL_MAX_INPUT_FROM = KERNEL_MAX_DEPENDENCIES_PER_TASK + 1
      MAX_TASKS_PAYLOAD_BYTES = Nexus::StepBounds::MAX_TASKS_PAYLOAD_BYTES
      # ONE tool step's input, measured where the row measures it: the
      # `tool_input` column's `bounded_json` bound. The batch bound above is
      # sixteen times larger, so a single oversized step used to pass it and
      # raise at the row's `create!` — a generic 422 at the HTTP door, and on
      # a kernel append a raise inside the converger that retried forever.
      TOOL_INPUT_BOUND = Nexus::StepBounds::TOOL_INPUT_BOUND
      TOOL_INPUT_TOO_LARGE = "tool_input_too_large".freeze
      # An input the row store cannot hold: not an object, or text or a number
      # the canonical encoder refuses (U+0000 among the text).
      INVALID_TOOL_INPUT = "invalid_tool_input".freeze
      # The node column that keeps a tool's name is string(128).
      MAX_TOOL_NAME_LENGTH = 128
      MAX_TIMEOUT_MS = 7.days.in_milliseconds
      MAX_RETRY_BUDGET = 5

      # The two marks, with one writer: `round` for a model step placed on the
      # loop's own path, `branch` for every other model step.
      ROUND = AgentLoopNodes::ModelTask::ROUND
      BRANCH = AgentLoopNodes::ModelTask::BRANCH

      DEFAULT_VISIBILITY_BY_KIND = {
        "model_task" => "visible", "tool_task" => "collapsed", "script_task" => "collapsed",
        "await_task" => "hidden", "join_task" => "hidden", "delegation_task" => "hidden",
      }.freeze
      # A failed tool call propagates, a failed model call halts; the
      # kernel's own fans are authored `absorb`, so this default governs
      # authored tasks only.
      DEFAULT_ON_FAILURE_BY_KIND = {
        "model_task" => "halt", "tool_task" => "propagate", "script_task" => "halt",
        "await_task" => "propagate", "join_task" => "propagate", "delegation_task" => "absorb",
      }.freeze

      LOSER_POLICY_BY_WORD = { "cancel" => "cancel_losers", "run_out" => "run_out" }.freeze
      DEFAULT_LOSERS = "cancel".freeze

      Result = Data.define(:nodes, :edges, :errors, :tip, :mirror) do
        def valid? = errors.empty?
        def keys = nodes.map { |node| node["node_key"] }
      end

      class << self
        # `headed:` says a spliced head follows the envelope, so an `all` fan
        # may end it; `mint:` prefixes the keys the door mints; `persisted:`
        # is the door's lookup of the names that are rows of earlier appends,
        # each answered with the keys that stand for it now.
        def call(steps, tip, kernel: false, headed: false, mint: "", held: false, key_generator: nil, persisted: nil)
          new(steps, tip, kernel: kernel, headed: headed, mint: mint, held: held, key_generator: key_generator,
            persisted: persisted).call
        end

        # A name a tool row can hold. The round driver reads the same rule,
        # so a call whose name this refuses is failed on its own rather than
        # refusing the whole round it arrived in.
        def storable_tool_name?(name)
          !name.empty? && name.length <= MAX_TOOL_NAME_LENGTH && !name.include?("\u0000")
        end
      end

      # `held`: the kernel itself holds this append's await token (the
      # waited `spawn`) — the await is a rendezvous the kernel settles,
      # not a person's question, so its expiry policy is its own.
      def initialize(steps, tip, kernel:, headed:, mint:, held: false, key_generator: nil, persisted: nil)
        @steps = steps
        @tip = tip
        @kernel = kernel
        @held = held
        @headed = headed
        @mint = mint
        @key_generator = key_generator
        @persisted = persisted
        @errors = []
        @nodes = []
        @edges = []
        @edge_index = {}
        @mirror = []
        @seen = {}
        @local_keys = {}
        @referenceable = {}
        @extra_waits = {}
        @detached_steps = Set.new
        @counters = Hash.new(0)
      end

      def call
        return refuse_batch("steps_must_be_an_array") if Array.try_convert(@steps).nil?

        steps = normalized_steps
        return Result.new(nodes: [], edges: [], errors: @errors, tip: @tip, mirror: []) if steps.nil?
        return refuse_batch("too_many_steps") if leaf_count(steps) > max_tasks
        return refuse_batch("steps_payload_too_large") if oversized?(steps)

        cursor = @tip
        steps.each_with_index do |step, index|
          placed = place(step, cursor, "steps[#{index}]", @mirror)
          return failed if placed.nil?

          cursor = placed
        end
        refuse_end(cursor, "steps[#{steps.length - 1}]") if steps.any?
        return failed if @errors.any?

        Result.new(nodes: @nodes, edges: @edges, errors: [], tip: cursor, mirror: @mirror)
      end

      private

        def failed = Result.new(nodes: [], edges: [], errors: @errors, tip: @tip, mirror: [])

        def refuse_batch(code)
          @errors << { "code" => code }
          failed
        end

        def refuse(code, path)
          @errors << { "code" => code, "path" => path }
          nil
        end

        # The door's wire is normalised here, once; a kernel author's values
        # pass through as written.
        def normalized_steps
          return @steps if @kernel

          @steps.each_with_index.map { |step, index| Step.from_h(step, "steps[#{index}]") }
        rescue Step::Refusal => error
          @errors << { "code" => error.refused.code, "path" => error.refused.path }
          nil
        end

        def leaf_count(steps)
          steps.sum do |step|
            sequence = Array.try_convert(step)
            next leaf_count(sequence) if sequence
            step.verb == "parallel" ? leaf_count(step.members) : 1
          end
        end

        def max_tasks = @kernel ? KERNEL_MAX_TASKS_PER_REQUEST : MAX_TASKS_PER_REQUEST
        def max_dependencies = @kernel ? KERNEL_MAX_DEPENDENCIES_PER_TASK : MAX_DEPENDENCIES_PER_TASK
        # +1 admits the spine on top of a full fan-in.
        def max_input_from = max_dependencies + 1

        def oversized?(steps)
          steps.map(&:to_h).to_json.bytesize > MAX_TASKS_PAYLOAD_BYTES
        end

        # An `all` fan is a set, not an answer, so an authored envelope may not
        # end on one; a seed of only detached steps has no tip to deliver. A
        # kernel envelope with a head to splice under may end on a fan, and so
        # may a DETACHED one: nothing follows it, and each of its tips is a
        # receipt the wake delivers on its own.
        def refuse_end(cursor, path)
          return if @kernel && (@headed || @tip.detached)

          refuse("fan_needs_follower", path) if cursor.waits.length > 1
          refuse("seed_needs_a_tip", path) if !@kernel && cursor.waits.empty?
        end

        # The cursor after placing `step`, or nil on refusal.
        def place(step, cursor, path, mirror)
          send(:"place_#{step.verb}", step, cursor, path, mirror)
        end

        def place_tool(step, cursor, path, mirror)
          key = claim_key(step.key, "tool", path) or return nil
          node = base_attributes(step, key, "tool_task", cursor, path) or return nil
          return refuse("invalid_tool_call_id", "#{path}.tool_call_id") if
            !@kernel && !step.tool_call_id.nil?
          return refuse("invalid_tool_call_id", "#{path}.tool_call_id") unless storable_call_id?(step.tool_call_id)
          return refuse("invalid_tool_alias", "#{path}.alias") if !@kernel && !step.alias.nil?

          name = step.name.to_s
          return refuse("reserved_tool_name", "#{path}.name") if
            !@kernel && Nexus::ToolRegistry.kernel_name?(name)
          return refuse("invalid_tool_name", "#{path}.name") unless self.class.storable_tool_name?(name)

          input = step.input.nil? ? {} : step.input
          return refuse(INVALID_TOOL_INPUT, "#{path}.input") if
            Hash.try_convert(input).nil? || !storable_json?(input)
          return refuse(TOOL_INPUT_TOO_LARGE, "#{path}.input") unless
            Nexus::SizeBounds.json_within?(TOOL_INPUT_BOUND, input)

          timeout = compile_timeout(step.timeout_ms, path)
          return nil if timeout == :error

          node.merge!(
            "tool_call_id" => step.tool_call_id.presence, "tool_name" => name,
            "tool_alias" => step.alias.presence, "tool_input" => input, "timeout_ms" => timeout
          )
          node["lifecycle_event"] = step.lifecycle_event if @kernel && step.lifecycle_event
          accumulate(step, cursor, node, mirror)
        end

        def place_ask(step, cursor, path, mirror)
          key = claim_key(step.key, "ask", path) or return nil
          node = base_attributes(step, key, "await_task", cursor, path) or return nil
          timeout = compile_timeout(step.timeout_ms, path)
          return nil if timeout == :error

          prompt = compile_prompt(step.prompt, path)
          return nil if prompt == :error
          return refuse("invalid_ask_options", "#{path}.options") unless
            step.options.nil? || (Array.try_convert(step.options)&.all?(String) && storable_json?(step.options))
          return refuse("invalid_ask_multi", "#{path}.multi") unless [nil, true, false].include?(step.multi)

          node.merge!("await_timeout_ms" => timeout, "prompt" => prompt,
            "ask_options" => step.options, "ask_multi" => step.multi)
          accumulate(step, cursor, node, mirror)
        end

        def place_delegation(step, cursor, path, mirror)
          key = claim_key(step.key, "delegation", path) or return nil
          node = base_attributes(step, key, "delegation_task", cursor, path) or return nil
          accumulate(step, cursor, node, mirror)
        end

        def place_wait(step, cursor, path, mirror)
          key = claim_key(step.key, "wait", path) or return nil
          node = base_attributes(step, key, "await_task", cursor, path) or return nil
          task = step.task.to_s
          return refuse("invalid_task_key", "#{path}.task") unless task.match?(TASK_KEY_FORMAT)

          timeout = compile_timeout(step.timeout_ms, path)
          return nil if timeout == :error

          node.merge!("await_timeout_ms" => timeout, "awaited_task_key" => task,
            "awaited_agent_loop_public_id" => step.agent_loop&.to_s)
          accumulate(step, cursor, node, mirror)
        end

        def place_script(step, cursor, path, mirror)
          key = claim_key(step.key, "script", path) or return nil
          node = base_attributes(step, key, "script_task", cursor, path) or return nil
          source = String.try_convert(step.script)
          return refuse("script_required", "#{path}.script") if source.nil? || source.strip.empty?
          return refuse("script_too_large", "#{path}.script") if source.bytesize > Nexus::Compose::Evaluator::MAX_SOURCE_BYTES
          return refuse("invalid_script", "#{path}.script") unless storable_json?(source)
          params = step.params.nil? ? {} : Hash.try_convert(step.params)
          return refuse("invalid_script_params", "#{path}.params") if params.nil? || !storable_json?(params)

          defaults = compile_model_defaults(step.model_defaults, path)
          return nil if defaults == :error

          node["script_definition"] = { "script" => source, "params" => params, "model_defaults" => defaults }
          accumulate(step, cursor, node, mirror)
        end

        def compile_model_defaults(value, path)
          return {} if value.nil?

          fields = Hash.try_convert(value)&.transform_keys(&:to_s)
          if fields.nil? || (fields.keys - Step::MODEL_DEFAULT_FIELDS).any?
            return refuse("invalid_model_defaults", "#{path}.model_defaults") || :error
          end
          step = Step.from_h({ "model" => fields }, "#{path}.model_defaults")
          model = {}
          return :error unless compile_model_fields(step, model, "#{path}.model_defaults", model_required: false)
          return :error if compile_retries(step, "model_task", "#{path}.model_defaults") == :error
          if step.on_failure && !AgentLoopNode::ON_FAILURE_POLICIES.include?(step.on_failure)
            return refuse("invalid_on_failure", "#{path}.model_defaults.on_failure") || :error
          end

          fields.merge("tools" => model["tool_definitions"]).compact
        end

        # A leaf becomes what the next step waits on; a detached step changes
        # nothing. It grows the material the next model reads only as the
        # round's own paired call — a `tool_call_id` is a fact only the kernel
        # writes — so every authored tool, ask, wait, stage and delegation is
        # a value a later step must name.
        def accumulate(step, cursor, node, mirror)
          known = Known.new(key: node["node_key"], kind: node["type"].demodulize.underscore, mark: nil)
          emit(node, cursor, mirror)
          return aside(node, cursor) if step.detached

          reads = node["tool_call_id"].present? ? cursor.reads + [known] : cursor.reads
          cursor.with(waits: [known], reads: reads)
        end

        # One arm for every model step. On the loop's own path it continues the
        # spine the tip hands it and reads the material behind the tip — the
        # round's paired calls, or what a kernel tip handed in — beside what it
        # names, and becomes the spine; anywhere else it is a fresh agent that
        # reads its prompt and what it names. A subagent (`detached`) starts
        # from its brief, and its own rounds stay off the spine.
        def place_model(step, cursor, path, mirror)
          key = claim_key(step.key, "model", path) or return nil
          node = base_attributes(step, key, "model_task", cursor, path) or return nil
          return nil unless compile_model_fields(step, node, path)

          continues = !step.detached && continues?(cursor)
          material, results = cursor.reads.partition { |known| !known.result_only }
          reads = continues ? [cursor.spine, *material].compact : []
          explicit = Array(node["result_from_node_keys"])
          result_keys = continues ? (results.map(&:key) - explicit) + explicit : explicit
          return refuse("too_many_reads", path) if (reads.map(&:key) | result_keys).length > max_input_from

          node.merge!(
            "continuation_source" => (step.detached ? BRANCH : cursor.mark),
            "input_from_node_keys" => reads.map(&:key).presence,
            "result_from_node_keys" => result_keys.presence
          )
          emit(node, cursor, mirror)
          return aside(node, cursor) if step.detached

          known = Known.new(key: key, kind: "model_task", mark: cursor.mark)
          continues ? cursor.with(spine: known, waits: [known], reads: []) : cursor.with(waits: [known])
        end

        # A step its author detached is a branch nothing here waits for: the
        # cursor stays where it was, and no race it sits beside stands for it.
        def aside(node, cursor)
          @detached_steps << node["node_key"]
          cursor
        end

        # Two facts the kernel already writes: the loop's own path is marked
        # `round`, and a kernel author continuing a round hands its spine in.
        def continues?(cursor) = cursor.mark == ROUND || !cursor.spine.nil?

        def compile_model_fields(step, node, path, model_required: true)
          model = Hash.try_convert(step.model)&.transform_keys(&:to_s)
          ref = Nexus::ModelRef.parse(model && model["model"].to_s)
          effort = model && model["reasoning_effort"].to_s
          if (model_required || !step.model.nil?) &&
              (!ref.complete? || ref.provider_id.length > 64 || ref.model_ref.length > 128 || effort.to_s.length > 32)
            return refuse("invalid_model", "#{path}.model")
          end

          configuration = step.configuration.nil? ? {} : step.configuration
          if Hash.try_convert(configuration).nil? || !storable_json?(configuration)
            return refuse("invalid_configuration", "#{path}.configuration")
          end

          prompt = compile_prompt(step.prompt, path)
          return nil if prompt == :error
          return refuse("prompt_required", "#{path}.prompt") if model_required && !@kernel && prompt.blank?

          attachments = compile_attachments(step.attachments, path)
          return nil if attachments == :error

          tools = compile_tools(step.tools, path)
          return nil if tools == :error

          compaction = step.compaction
          if !compaction.nil? &&
              !(Nexus::CompactionPolicy.well_formed?(compaction) && storable_json?(compaction))
            return refuse("invalid_compaction", "#{path}.compaction")
          end

          fan_on_failure = step.fan_on_failure
          if fan_on_failure.present? && !%w[absorb propagate].include?(fan_on_failure)
            return refuse("invalid_fan_on_failure", "#{path}.fan_on_failure")
          end

          instructions = step.instructions
          case instructions
          when nil then nil
          when String
            if instructions.empty? || instructions.include?("\u0000")
              return refuse("invalid_instructions", "#{path}.instructions")
            end
          else return refuse("invalid_instructions", "#{path}.instructions")
          end

          node.merge!(
            "provider_id" => ref.provider_id, "model_ref" => ref.model_ref,
            "reasoning_effort" => model&.fetch("reasoning_effort", nil).presence,
            "request_options" => configuration, "tool_definitions" => tools,
            "system_instructions" => instructions, "fan_on_failure" => fan_on_failure.presence,
            "compaction" => compaction, "prompt" => prompt.presence, "attachments" => attachments
          )
        end

        # The pictures beside a model step's prompt: a list of upload
        # public ids, canonicalized here so a malformed one refuses
        # positionally; the member door's word alone — a kernel author
        # naming one is refused, never granted (the agent user holds no
        # uploads, and the door's creator is who they resolve against).
        def compile_attachments(value, path)
          return nil if value.nil?

          if @kernel
            refuse("attachments_not_authorable", "#{path}.attachments")
            return :error
          end

          ids = Array.try_convert(value)
          canonical = ids&.map { |id| ContentUpload.canonical_public_id(id) }
          if canonical.nil? || canonical.empty? || canonical.any?(&:nil?)
            refuse("invalid_attachments", "#{path}.attachments")
            return :error
          end

          canonical
        end

        # Stored verbatim in the wire families' own shapes. An empty array
        # is a typo'd intent: it reads like disabling something never on.
        def compile_tools(entries, path)
          return nil if entries.nil?

          unless Nexus::ToolDeclarations.entries?(entries)
            refuse("invalid_tools", "#{path}.tools")
            return :error
          end

          refusal = Nexus::ToolDeclarations.refusal(entries)
          if refusal
            refuse(refusal, "#{path}.tools")
            return :error
          end

          # The round's set is the RENDER, as the profile's is: an alias's
          # function block is what the wire sends, its facts beside it are
          # what the round's resolution reads.
          Nexus::ToolDeclarations::Render.render(Nexus::ToolDeclarations.canonical(entries))
        end

        # Every member is placed at the group's entry as a fresh branch: the
        # entry clears the spine, so a member neither continues the round nor
        # becomes a spine. The group contributes its members' exits and its
        # content — only ever the kernel's own fan's paired calls, the one
        # material a group grows, which the continuation reads; a race adds
        # the one barrier row the kernel places.
        def place_parallel(step, cursor, path, mirror)
          return refuse("empty_parallel", path) if step.members.empty?

          lifetime = lifetime_for(step, cursor, path) or return nil
          wake = wake_for(step, cursor, path) or return nil

          ends = compile_until(step, path)
          return nil if ends == :error
          return refuse("too_wide_a_fan", path) if step.members.length > max_dependencies

          exits = []
          content = []
          members = []
          arms = @nodes.length
          entry = cursor.with(mark: BRANCH, spine: nil, lifetime: lifetime, wake: wake)
          step.members.each_with_index do |member, index|
            local = place_member(member, entry, "#{path}.parallel[#{index}]", members)
            return nil if local.nil?

            exits |= local.waits
            content += local.reads - entry.reads
          end
          return refuse("too_wide_a_fan", path) if exits.length > max_dependencies

          if ends == "all"
            mirror << { "parallel" => members }
            return cursor.with(waits: exits, reads: cursor.reads + content)
          end

          join = place_join(step, ends, exits - cursor.waits, exits, cursor.with(lifetime: lifetime, wake: wake), path)
          return nil if join.nil?

          mark_arms(@nodes[arms...-1], join.key)
          mirror << { "parallel" => members, "key" => join.key }
          cursor.with(waits: [join], reads: cursor.reads + content)
        end

        # THE BARRIER STANDS FOR ITS ARMS: every row placed in a race's arms,
        # at any depth, carries the nearest race's key — the persisted fact
        # the delivery reads, since the settle-time loser walk leaves nothing
        # durable. The barrier row is placed after its arms, so they are
        # stamped once it has a key; a nested race stamped its own first. A
        # step its author detached is no arm's: the race neither waits for
        # nor stops it, so it comes back on its own.
        def mark_arms(nodes, barrier_key)
          nodes.each do |node|
            node["barrier_key"] ||= barrier_key unless @detached_steps.include?(node["node_key"])
          end
        end

        # A nested sequence runs under a local cursor from the group's entry.
        def place_member(member, entry, path, members)
          sequence = Array.try_convert(member)
          return place(member, entry, path, members) if sequence.nil?

          nested = []
          members << nested
          local = entry
          sequence.each_with_index do |step, index|
            local = place(step, local, "#{path}[#{index}]", nested)
            return nil if local.nil?
          end
          local
        end

        # `until` is a Ruby keyword: read as `step.until`, never bound bare —
        # the result lives in `ends`.
        def compile_until(step, path)
          racing = !step.until.nil? && step.until != "all"
          unless racing
            refuse("key_needs_a_race", "#{path}.key") unless step.key.nil?
            refuse("invalid_losers", "#{path}.losers") unless step.losers.nil?
            refuse("invalid_on_failure", "#{path}.on_failure") unless step.on_failure.nil?
            return @errors.any? ? :error : "all"
          end

          case step.until
          when "any" then "any"
          when Integer
            return step.until if step.until.positive?

            refuse("invalid_until", "#{path}.until") || :error
          else refuse("invalid_until", "#{path}.until") || :error
          end
        end

        # The barrier row's in-degree is frozen at birth, so a race that can
        # never be satisfied is refused before any row exists. Once placed, a
        # later step may name the race in `after`/`results`: it waits on the
        # barrier alone and reads what the race selected, so a reference never
        # keeps a loser alive. A race reaches a reader only by that name.
        def place_join(step, ends, own_exits, exits, cursor, path)
          mode = ends == "any" ? "any" : "quorum"
          quorum_k = ends == "any" ? nil : ends
          if own_exits.empty? || (quorum_k && quorum_k > own_exits.length)
            return refuse("unsatisfiable_until", "#{path}.until")
          end

          key = claim_key(step.key, "parallel", path) or return nil
          losers = step.losers.nil? ? DEFAULT_LOSERS : step.losers
          policy = LOSER_POLICY_BY_WORD[losers] or return refuse("invalid_losers", "#{path}.losers")
          on_failure = step.on_failure.nil? ? DEFAULT_ON_FAILURE_BY_KIND.fetch("join_task") : step.on_failure
          return refuse("invalid_on_failure", "#{path}.on_failure") unless
            AgentLoopNode::ON_FAILURE_POLICIES.include?(on_failure)

          node = {
            "node_key" => key, "type" => AgentLoopNodes::JoinTask.name,
            "on_failure" => on_failure, "transcript_visibility" => "hidden",
            "detached" => cursor.detached, "retry_budget" => 0, "lifetime" => cursor.lifetime, "wake" => cursor.wake,
            "join_mode" => mode, "quorum_k" => quorum_k, "loser_policy" => policy,
          }
          @nodes << node
          exits.each { |exit| emit_edge(exit.key, key, structural: true) }
          @referenceable[@local_keys.fetch(key)] = key
          Known.new(key: key, kind: "join_task", mark: nil)
        end

        # The node's row and its order edges from everything the tip waits on.
        def emit(node, cursor, mirror)
          @nodes << node
          key = node["node_key"]
          cursor.waits.each { |wait| emit_edge(wait.key, key, structural: true) }
          @extra_waits.fetch(key, []).each { |source| emit_edge(source, key, structural: false) }
          @referenceable[@local_keys.fetch(key)] = key
          mirror << node["node_key"]
        end

        def emit_edge(from, to, structural:)
          endpoint = [from, to]
          if (existing = @edge_index[endpoint])
            existing["structural"] ||= structural
          else
            edge = { "from_key" => from, "to_key" => to, "structural" => structural }
            @edges << edge
            @edge_index[endpoint] = edge
          end
        end

        def claim_key(given, verb, path)
          key = given.nil? ? mint(verb) : given.to_s
          return refuse("invalid_task_key", "#{path}.key") unless key.match?(TASK_KEY_FORMAT)
          return refuse("duplicate_task_key", "#{path}.key") if @seen.key?(key)

          actual = @key_generator ? @key_generator.call : key
          @seen[key] = actual
          @local_keys[actual] = key
          actual
        end

        # Pure in position: the same envelope mints the same keys again.
        def mint(verb)
          @counters[verb] += 1
          "#{@mint}#{verb}-#{@counters[verb]}"
        end

        def base_attributes(step, key, kind, cursor, path)
          return refuse("too_wide_a_fan", path) if cursor.waits.length > max_dependencies

          lifetime = lifetime_for(step, cursor, path) or return nil
          wake = wake_for(step, cursor, path) or return nil

          default_failure = step.verb == "wait" ? "absorb" : DEFAULT_ON_FAILURE_BY_KIND.fetch(kind)
          on_failure = step.on_failure.nil? ? default_failure : step.on_failure
          return refuse("invalid_on_failure", "#{path}.on_failure") unless
            AgentLoopNode::ON_FAILURE_POLICIES.include?(on_failure)
          # A kernel await is a model's ask — tokenless, answerable only by a
          # person — so its expiry must HOLD the loop for one, whatever the
          # author wrote or its position implied. A kernel-HELD await (the
          # waited spawn) is nobody's question: its expiry is detach +
          # notify, the step's own `absorb`.
          on_failure = "halt" if @kernel && !@held && kind == "await_task" && step.verb != "wait"

          visibility = step.visibility.nil? ? DEFAULT_VISIBILITY_BY_KIND.fetch(kind) : step.visibility
          return refuse("invalid_visibility", "#{path}.visibility") unless
            AgentLoopNode::TRANSCRIPT_VISIBILITIES.include?(visibility)

          retries = compile_retries(step, kind, path)
          return nil if retries == :error
          return refuse("invalid_detached", "#{path}.detached") unless
            [true, false].include?(step.detached)

          # The cursor's detachment is the subgraph's (a detached compose
          # call, a detached branch's own rounds); the step's is the door's.
          node = {
            "node_key" => key, "type" => AgentLoopNodes.type_for_kind(kind).name,
            "on_failure" => on_failure, "transcript_visibility" => visibility,
            "detached" => cursor.detached || step.detached, "retry_budget" => retries,
            "lifetime" => lifetime, "wake" => wake,
          }
          return nil unless compile_references(step, node, cursor, path, kind)

          node
        end

        def compile_references(step, node, cursor, path, kind)
          return true if kind == "delegation_task"

          after = reference_keys(step.after, "#{path}.after")
          return false if after.nil?

          results = Nexus::Compose::Reads.reads?(step.verb) ? reference_keys(step.results, "#{path}.results") : []
          return false if results.nil?

          waits = after | results
          if (cursor.waits.map(&:key) | waits).length > max_dependencies
            return refuse("too_many_dependencies", path)
          end
          node["result_from_node_keys"] = results.presence
          @extra_waits[node["node_key"]] = waits
          true
        end

        # Only already emitted leaves and placed races qualify. Neither an
        # inherited cursor nor a claimed but not yet emitted key can introduce
        # a forward reference — a race's members are placed before its barrier,
        # so none of them can name it. The door's one widening: an authored
        # envelope may name a row of an earlier append by its key, which is
        # how a client driving the loop hands a value across appends — read
        # and waited on as what stands for it now; the kernel's own
        # envelopes hand values through their tips instead.
        def reference_keys(value, path)
          return [] if value.nil?

          keys = Array.try_convert(value)
          names = keys&.map { |key| String.try_convert(key) }
          if names.nil? || names.any?(&:nil?) || names.any? { |key| !key.match?(TASK_KEY_FORMAT) }
            return refuse("invalid_task_references", path)
          end
          return refuse("duplicate_task_reference", path) if names.uniq.length != names.length

          earlier = names.reject { |key| @referenceable.key?(key) }
          standing = persisted(earlier)
          return refuse("unknown_task_reference", path) unless (earlier - standing.keys).empty?

          names.flat_map { |key| @referenceable.key?(key) ? [@referenceable.fetch(key)] : standing.fetch(key) }.uniq
        end

        # What each earlier row's name stands for now, one query per
        # reference list; the dependency bound refuses a long one right after.
        def persisted(keys) = keys.empty? || @persisted.nil? ? {} : @persisted.call(keys)

        # Member-authored values are validated once here. Kernel writers
        # inherit stored values or the lifetime their tool boundary resolved.
        def lifetime_for(step, cursor, path)
          return cursor.lifetime if step.lifetime.nil?
          return step.lifetime if @kernel || AgentLoopNode::LIFETIMES.include?(step.lifetime)

          refuse("invalid_lifetime", "#{path}.lifetime")
        end

        def wake_for(step, cursor, path)
          return cursor.wake if step.wake.nil?
          return step.wake if @kernel || AgentLoopNode::WAKE_MODES.include?(step.wake)

          refuse("invalid_wake", "#{path}.wake")
        end

        # `retry` re-runs a MODEL step (the converger's budget); a tool or
        # an ask parks on its holder and has no budget to spend, so a kernel
        # author naming one is refused here — the wire already refuses it as
        # an unknown option.
        def compile_retries(step, kind, path)
          budget = step.retries
          return 0 if budget.nil?

          case budget
          when Integer
            return budget if budget.between?(0, MAX_RETRY_BUDGET) && kind == "model_task"
          else nil
          end
          refuse("invalid_retry", "#{path}.retry")
          :error
        end

        def compile_prompt(prompt, path)
          case prompt
          when nil then nil
          when String
            return refuse("invalid_prompt", "#{path}.prompt") || :error if prompt.include?("\u0000")

            prompt
          else refuse("invalid_prompt", "#{path}.prompt") || :error
          end
        end

        def compile_timeout(value, path)
          return nil if value.nil?

          case value
          when Integer
            return value if value.positive? && value <= MAX_TIMEOUT_MS
          else nil
          end
          refuse("invalid_timeout_ms", "#{path}.timeout_ms")
          :error
        end

        # A kernel step's pairing key is the provider's, normalized to a
        # String and bounded by the one normalizer (`Nexus::ModelToolCalls`).
        # It is checked again here because it is written to a string(128)
        # column, and a refusal is an answer the kernel's caller can report
        # where a raise at the row's `create!` is not.
        def storable_call_id?(id)
          id.nil? || (id.length <= Nexus::ModelToolCalls::MAX_ID_LENGTH && !id.include?("\u0000"))
        end

        # A value the row store cannot hold is a typed refusal HERE, never an
        # INSERT-time 500 — the one predicate every reader of this rule asks.
        def storable_json?(value) = Nexus::CanonicalJson.storable?(value)
    end
  end
end
