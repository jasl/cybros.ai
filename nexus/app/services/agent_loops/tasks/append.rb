module AgentLoops
  module Tasks
    # The one append door: every structural mutation lands here under the
    # loop lock. The tip is derived (an authored envelope) or handed in (a
    # kernel author) under that lock, so the lowering sees the graph it joins.
    class Append
      # A refusal after rows were written takes the whole batch back, and
      # this door can run inside a caller's transaction — so its own savepoint.
      class Refused < StandardError
        attr_reader :code

        def initialize(code)
          @code = code
          super(code.to_s)
        end
      end

      # The writers the stage reads: a kernel command names its `origin`;
      # the authored door's word is `author`, retained when its script expands.
      # This is an internal command, never a caller-selectable approval grant.
      KERNEL_ORIGINS = %w[model kernel author].freeze

      # WHO HOLDS a kernel await's token: nil for the tokenless ask a
      # person answers to write standing; `:kernel` for a rendezvous the
      # kernel itself settles (`trusted: true`) — the waited spawn — so the
      # row parks `dispatched`, off every inbox, never announced as a
      # person's question. No new state: the tokened word already exists
      # for an authored await.
      HOLDERS = [nil, :kernel].freeze

      # `creator` is the member the authored door acts as: whose staged
      # uploads a step's `attachments` resolve against — the loop's
      # creator at the create door, the acting member at the append door.
      # A kernel command has none and names no attachments.
      Command = Data.define(
        :agent_loop, :steps, :resolves, :expected_revision, :idempotency_key,
        :authored, :tip, :head, :splice_reads, :replaces, :origin, :holder, :creator,
        :expansion_parent, :key_generator
      ) do
        def self.authored(agent_loop:, steps:, resolves: nil, expected_revision: nil,
                          idempotency_key: nil, creator: nil)
          new(agent_loop:, steps:, resolves:, expected_revision:, idempotency_key:,
              authored: true, tip: nil, head: nil, splice_reads: false, replaces: nil, origin: nil,
              holder: nil, creator:, expansion_parent: nil, key_generator: nil)
        end

        # A kernel author says where it starts (the tip), may splice a queued
        # `head` under the envelope's end, and may hand every queued consumer
        # of `replaces` to that end. `revision` does not tick and no CAS applies.
        # `origin` names the writer the stage reads: `model` for what a round
        # or a composed graph asked, `kernel` for what the kernel planted —
        # REQUIRED, because an unlabelled kernel writer would be a silent grant.
        def self.kernel(agent_loop:, steps:, tip:, origin:, head: nil, splice_reads: true, replaces: nil,
                        holder: nil, expansion_parent: nil, key_generator: nil)
          raise ArgumentError, "origin must be one of #{KERNEL_ORIGINS.join("|")}" unless
            KERNEL_ORIGINS.include?(origin)
          raise ArgumentError, "holder must be nil or :kernel" unless HOLDERS.include?(holder)

          new(agent_loop:, steps:, resolves: nil, expected_revision: nil, idempotency_key: nil,
              authored: false, tip:, head:, splice_reads:, replaces:, origin:, holder:, creator: nil,
              expansion_parent:, key_generator:)
        end

        # The token is minted where somebody can hold it: an authored
        # append's receipt, or the kernel itself (`holder: :kernel`).
        def mints_token? = authored || holder == :kernel

        # The word every row this command creates carries: the append door
        # is a principal's write, a kernel command says its own.
        def authored_by = authored ? "author" : origin
      end

      Result = Data.define(:outcome, :receipt, :errors, :response_status) do
        class << self
          def applied(receipt)
            new(outcome: :applied, receipt: receipt, errors: [], response_status: 201)
          end

          def replayed(record)
            new(outcome: :replayed, receipt: record.response_body, errors: [],
                response_status: record.response_status)
          end

          def refused(code)
            new(outcome: code, receipt: nil, errors: [], response_status: nil)
          end

          def invalid(errors)
            new(outcome: :invalid_steps, receipt: nil, errors: errors, response_status: nil)
          end
        end

        def applied? = outcome == :applied
        def replayed? = outcome == :replayed
      end

      # Ordinary background results carry content; a successful join is
      # structural — never material — and a race named as a RESULT reads
      # what it selected, not a body of its own (`TaskResultProjection.referenced`).
      READABLE_TYPES = [
        AgentLoopNodes::ModelTask, AgentLoopNodes::ToolTask, AgentLoopNodes::AwaitTask,
        AgentLoopNodes::DelegationTask, AgentLoopNodes::ScriptTask,
      ].map(&:sti_name).freeze

      class << self
        def call(command)
          new(command).call
        end

        # Settlement already holds the loop, possibly with a node or body
        # lock below it. Reuse the append transaction without acquiring an
        # earlier lock again.
        def call_locked(command)
          new(command).call(lock: false)
        end

        # Called under the loop lock before either source releases its
        # consumers. The finite wait remains a dependency; only its result
        # is replaced by the durable completion's result, exactly once.
        def replace_reads(agent_loop:, replaces:, reads:)
          Splice.replace_reads(agent_loop: agent_loop, replaces: replaces, reads: reads)
        end

        # WHICH JOIN A SLOT MAY NAME, one rule for the door and the splice.
        # Material never names a join, but a kernel wake may report a failed
        # race itself when no winning result can explain its failure; a
        # result may name a race, whatever it settled as, because it reads
        # the race's selection. `authored` is the door's word: an authored
        # envelope never reads a join as material.
        def unreadable_source?(source, result:, authored:)
          source.join_mode.present? && !(result && source.race?) && (authored || !source.failure?)
        end

        # An authored envelope starts from the loop's answer: its first step
        # waits on the deliverable, and a top-level model step continues the
        # spine's tail. Nothing carries across appends by position — a later
        # envelope names the rows it reads by key.
        def boundary_tip(loop_row)
          deliverable = loop_row.deliverable_node
          spine = loop_row.spine_tail
          Tip.new(
            spine: Known.of(spine), waits: [Known.of(deliverable)].compact, reads: [],
            mark: Compile::ROUND, detached: false, lifetime: spine&.lifetime || "conversation",
            wake: spine&.wake || "auto"
          )
        end
      end

      def initialize(command)
        @command = command
      end

      def call(lock: true)
        steps = Array.try_convert(@command.steps)
        return Result.invalid([{ "code" => "steps_must_be_an_array" }]) if steps.nil?
        return Result.invalid([{ "code" => "steps_required" }]) if
          steps.empty? && Array(@command.resolves).empty?

        AgentLoop.transaction(requires_new: true) do
          loop_row = @command.agent_loop
          loop_row.lock! if lock
          next Result.refused(:agent_loop_not_appendable) unless loop_row.graph_mutable?
          # The repair exit is an adjudication: behind a person's edit the
          # hold stays, and nothing is appended to a loop nobody reads.
          if loop_row.needs_attention? && loop_row.overridden?
            next Result.refused(:not_adjudicable)
          end

          replay = replayed_receipt(loop_row)
          next replay if replay

          if @command.expected_revision && @command.expected_revision != loop_row.revision
            next Result.refused(:stale_revision)
          end

          tip = @command.authored ? self.class.boundary_tip(loop_row) : @command.tip
          compiled = Compile.call(
            steps, tip, kernel: !@command.authored, headed: @command.head.present?,
            mint: ("s#{loop_row.revision + 1}-" if @command.authored).to_s,
            held: @command.holder == :kernel, key_generator: @command.key_generator,
            persisted: (persisted_lookup(loop_row) if @command.authored)
          )
          next Result.invalid(compiled.errors) unless compiled.valid?
          if @command.expansion_parent&.script? && !readable_finish?(compiled)
            next Result.refused(:script_requires_single_result)
          end
          if loop_row.delivered? && compiled.nodes.any? { |node| node["lifetime"] == "turn" }
            next Result.refused(:turn_already_delivered)
          end

          unreachable = delegate_refusals(loop_row, compiled)
          next Result.invalid(unreachable) if unreachable.any?

          refusal = tip_refusal(loop_row, tip, compiled)
          next Result.refused(refusal) if refusal

          apply(loop_row, tip, compiled)
        end
      rescue Refused => error
        Result.refused(error.code)
      end

      private

        # The recheck lives UNDER the lock: an identical retry can race
        # the original past any pre-check.
        def replayed_receipt(loop_row)
          key = @command.idempotency_key
          return nil if key.blank?

          # Release only this key's expired reservation under the loop lock.
          # The bounded reaper owns bulk cleanup of every other receipt.
          scope = loop_row.agent_loop_append_receipts.where(idempotency_key: key)
          scope.where(created_at: ...AgentLoopAppendReceipt::RETENTION.ago).delete_all
          receipt = scope.first
          return nil if receipt.nil?
          return Result.refused(:idempotency_envelope_mismatch) unless
            receipt.request_digest == request_digest

          Result.replayed(receipt)
        end

        def request_digest
          AgentLoopAppendReceipt.digest_for(
            "steps" => @command.steps, "resolve" => @command.resolves
          )
        end

        # The names an authored envelope's `after`/`results` may take beyond
        # its own steps: any row this loop already holds, each resolved to
        # what stands for it now — a row an expansion replaced is its final
        # waits (`ExpansionOwnership.standing`), so a name reads the work's
        # final answer, never its first draft or a stage's manifest; a row
        # still to be replaced is re-pointed by the splice when it expands.
        # What such a row may be read as is `validate_input_from`'s
        # question, answered at create.
        def persisted_lookup(loop_row)
          ->(keys) { ExpansionOwnership.standing(loop_row, keys) }
        end

        # ONE rule at ONE site: a delegated compaction is a tool call
        # addressed to the loop's declaring agent, and a loop with no
        # declaring profile — a Human's standalone loop — has no address to
        # reach. The compiler is loop-blind, so the door that holds the loop
        # answers, positionally, for the seed and for growth alike.
        DELEGATE_REFUSAL = "delegate_requires_agent_profile".freeze

        def delegate_refusals(loop_row, compiled)
          return [] if loop_row.declaring_profile.present?

          delegated = compiled.nodes.select do |node|
            node["type"] == AgentLoopNodes::ModelTask.sti_name &&
              Hash.try_convert(node["compaction"])&.dig("mode") == Conversations::Compaction::Summarizer::MODE_DELEGATE
          end.to_set { |node| node["node_key"] }
          return [] if delegated.empty?

          step_paths(compiled.mirror).filter_map do |key, path|
            { "code" => DELEGATE_REFUSAL, "path" => "#{path}.compaction" } if delegated.include?(key)
          end
        end

        # The mirror in the envelope's own order, each leaf with the path the
        # compiler would have named it by: `steps[i]`, `.parallel[j]`, `[k]`.
        def step_paths(mirror, path = "steps")
          mirror.each_with_index.flat_map do |entry, index|
            case entry
            when String then [[entry, "#{path}[#{index}]"]]
            when Array then step_paths(entry, "#{path}[#{index}]")
            when Hash then step_paths(entry.fetch("parallel"), "#{path}[#{index}].parallel")
            else []
            end
          end
        end

        # Two refusals before any row exists: a step that reads a spine still
        # talking (the input door's job), and an append past a tip whose
        # settlement is pending or skipped (adjudicate first).
        def tip_refusal(loop_row, tip, compiled)
          return nil unless @command.authored

          if tip.spine && reads_spine?(compiled, tip.spine.key)
            spine = loop_row.agent_loop_nodes.find_by(node_key: tip.spine.key)
            return :tip_live if spine && AgentLoopNode::LIVE_STATUSES.include?(spine.status)
          end

          waits = loop_row.agent_loop_nodes.where(node_key: tip.waits.map(&:key))
          unresolved = waits.any? do |node|
            node.terminal? && %i[pending skip].include?(Graph.settlement_of(node))
          end
          :tip_unresolved if unresolved
        end

        # Exact: a fresh group member or a branch reads nothing of the round,
        # so only a payload naming the spine in its input_from reads it.
        def reads_spine?(compiled, spine_key)
          compiled.nodes.any? { |node| Array(node["input_from_node_keys"]).include?(spine_key) }
        end

        def apply(loop_row, start, compiled)
          taken = loop_row.agent_loop_nodes.where(node_key: compiled.keys).pick(:node_key)
          raise Refused, :duplicate_task_key if taken

          created = create_nodes(loop_row, compiled)
          create_edges(loop_row, compiled, created)
          spliced = splice(loop_row, compiled, created)
          designate_deliverable(loop_row, start, compiled.tip, created)
          # Birth narration first, then the race endings: narrating from
          # the `created` hash afterwards would replay `waiting` over the cancel.
          Transition.created(loop_row, created.values)
          # Then the heads whose sources grew, still queued: a head the
          # splice settled (skipped at birth) already narrated its own move.
          Transition.spliced(loop_row, spliced.select { |head| head.status == "queued" })
          # After the edges exist: the loser closure walks `incoming_edges`,
          # and a newborn join has none until now.
          end_races(created.values)

          # AFTER the append, so a task authored in this same envelope may
          # already depend on the await it resolves.
          apply_resolves(loop_row)

          loop_row.update!(revision: loop_row.revision + 1) if @command.authored
          release_hold(loop_row)
          receipt = receipt_body(loop_row, compiled, created)
          persist_receipt(loop_row, receipt)
          Result.applied(receipt)
        end

        def splice(loop_row, compiled, created)
          Splice.new(loop_row, @command, compiled, created).call
        end

        def readable_finish?(compiled)
          return false unless compiled.tip.waits.one?

          key = compiled.tip.waits.sole.key
          payload = compiled.nodes.find { |node| node["node_key"] == key }
          payload && READABLE_TYPES.include?(payload.fetch("type"))
        end

        # Append from needs_attention is the designed repair exit: the hold
        # releases and quiescence re-holds if the repair did not resolve the rest.
        def release_hold(loop_row)
          return unless loop_row.needs_attention?

          Transition.agent_loop(
            loop_row,
            status: "running",
            attention_reason: nil
          )
        end

        # The forward creation pass. Sources for each node are persisted
        # rows or earlier-in-batch creations — the compiler guaranteed it
        # — so settlement is always known at creation time.
        def create_nodes(loop_row, compiled)
          persisted = persisted_sources(loop_row, compiled)
          created = {}
          compiled.nodes.each do |payload|
            sources = compiled.edges
              .select { |edge| edge["to_key"] == payload["node_key"] }
              .map do |edge|
                created[edge["from_key"]] || persisted[edge["from_key"]] ||
                  raise(Refused, :unknown_dependency)
              end
            created[payload["node_key"]] = create_node(loop_row, payload, sources)
          end
          mark_arms(compiled, created)
          created
        end

        # A race's arm rows precede its barrier row in the batch, so the
        # barrier each names is stamped once every row of the batch exists —
        # still inside the append that creates them. The only sanctioned
        # write of that readonly slot after create (`AgentLoopNode`), hence
        # `update_all`, which `attr_readonly` does not see.
        def mark_arms(compiled, created)
          compiled.nodes.select { |payload| payload["barrier_key"] }
            .group_by { |payload| payload["barrier_key"] }
            .each do |barrier, payloads|
              AgentLoopNode.where(id: payloads.map { |payload| created.fetch(payload["node_key"]).id })
                .update_all(barrier_node_id: created.fetch(barrier).id)
            end
        end

        def persisted_sources(loop_row, compiled)
          keys = compiled.edges.map { |edge| edge["from_key"] }.uniq - compiled.keys
          loop_row.agent_loop_nodes.where(node_key: keys).index_by(&:node_key)
        end

        # Every row carries WHO WROTE IT — rounds, joins and awaits
        # included: the column is a fact about every row, the approval
        # stage reads it on tool rows only. The compiler is writer-blind;
        # the door that holds the command stamps it.
        def create_node(loop_row, payload, sources)
          validate_input_from(loop_row, payload)
          prompt = payload["prompt"]
          attachments = payload["attachments"]
          bound = TaskWaits.bind(agent_loop: loop_row,
            attributes: payload.except("prompt", "attachments", "script_definition", "barrier_key"),
            expansion_parent: @command.expansion_parent)
          attributes = mint_resolution_token(bound)
            .merge("authored_by" => @command.authored_by,
              "expansion_parent_id" => @command.expansion_parent&.id,
              "barrier_node_id" => inherited_barrier(payload))
          settlements = sources.map { |source| Graph.settlement_of(source) }

          if Graph.skip_at_birth?(attributes["join_mode"], settlements)
            node = loop_row.agent_loop_nodes.create!(
              attributes.merge("status" => "skipped", "completed_at" => Time.current)
            )
          else
            countdown = Graph.initial_countdown(
              attributes["join_mode"], attributes["quorum_k"], settlements
            )
            node = loop_row.agent_loop_nodes.create!(
              attributes.merge("remaining_dependencies" => countdown)
            )
            evaluate_join(node, sources, settlements)
          end
          attach_prompt(node, prompt, attachments)
          attach_script(node, payload["script_definition"]) if payload.key?("script_definition")
          node
        end

        # What an arm's row expands into — a stage's children, a round's fan
        # and continuation, a run-out loser's late rounds — stays the arm's
        # when the compile placed it in no race of its own.
        def inherited_barrier(payload)
          @command.expansion_parent&.barrier_node_id unless payload["barrier_key"]
        end

        # The token is minted only where somebody holds it — an authored
        # append's receipt, or the kernel for a rendezvous it settles
        # itself (a waited spawn or an existing-task observation). A model's `g.ask`
        # mints none: it is answered to write standing, and a token nobody
        # held would make it answerable by nothing but its timeout.
        def mint_resolution_token(attributes)
          return attributes unless @command.mints_token? || attributes["awaited_task_key"]
          return attributes unless attributes["type"] == AgentLoopNodes::AwaitTask.sti_name

          attributes.merge("resolution_token" => SecureRandom.uuid)
        end

        # The door owns the persisted half: every named source must exist,
        # and a join only where `unreadable_source?` admits it. Several model
        # sources are material, not ambiguity.
        def validate_input_from(loop_row, payload)
          inputs = Array(payload["input_from_node_keys"])
          results = Array(payload["result_from_node_keys"])
          return if inputs.empty? && results.empty?

          sources = loop_row.agent_loop_nodes.where(node_key: (inputs + results).uniq).index_by(&:node_key)
          [[inputs, false], [results, true]].each do |keys, result|
            keys.each do |key|
              source = sources[key]
              raise Refused, :unknown_input_source if source.nil?
              raise Refused, :invalid_input_from_source if
                self.class.unreadable_source?(source, result: result, authored: @command.authored)
            end
          end
        end

        # A join whose sources already answer settles as it is born;
        # hanging is never an answer.
        def evaluate_join(node, sources, settlements)
          return if node.join_mode.nil?

          if node.remaining_dependencies.zero?
            node.update!(
              status: "completed",
              completed_at: Time.current,
              output_summary: {
                "joined" => node.join_mode,
                "outcomes" => Graph.join_outcomes(sources.index_by(&:node_key)),
              }
            )
          elsif (failure = Graph.join_failure(node.join_mode, node.quorum_k, settlements))
            node.update!(
              status: "failed",
              completed_at: Time.current,
              error_key: failure,
              output_summary: {
                "join_failure" => failure,
                "outcomes" => Graph.join_outcomes(sources.index_by(&:node_key)),
              }
            )
          end
        end

        # A join born settled either way ends its race: an unreachable
        # quorum's in-flight sources can no longer feed anything.
        def end_races(nodes)
          nodes.each do |node|
            next unless node.terminal?

            CancelLosers.call(node).each { |loser| Release.settled(loser) }
          end
        end

        # Completed outcomes only — an authoring envelope must never invert
        # a failure into success — and any entry failing fails the whole
        # envelope. Key-addressed: the caller already proved write standing.
        def apply_resolves(loop_row)
          entries = Array.try_convert(@command.resolves) || []
          return if entries.empty?
          raise Refused, :too_many_resolves if entries.length > Compile::MAX_TASKS_PER_REQUEST

          entries.each do |entry|
            payload = Hash.try_convert(entry) || { "task" => entry }
            key = payload["task"].to_s
            raise Refused, :resolve_task_required if key.empty?
            if payload.key?("outcome") && payload["outcome"] != "completed"
              raise Refused, :unsupported_resolve_outcome
            end

            node = loop_row.agent_loop_nodes.find_by(
              node_key: key, type: AgentLoopNodes::AwaitTask.sti_name
            )
            raise Refused, :unknown_await if node.nil?

            result = Parks::Settle.call(
              node: node, claim_token: node.resolution_token,
              content: payload["content"], outcome: "completed"
            )
            raise Refused, :await_not_resolvable unless result.settled?
          end
        end

        # A step's words, and its pictures beside them: the same composer
        # as the input doors — one parts entry, the joins bound and pinned,
        # the words as `readable_text` (what the summarizer's
        # `authored_prompt` and rho's `inputs` line read). Resolved against
        # the door's creator; a command with none refuses by name.
        def attach_prompt(node, prompt, attachments = nil)
          return if prompt.blank?

          message = attached_message(node, prompt, attachments)
          raise Refused, message.refusal unless message.accepted?

          result = ContentBodies::Replace.call(
            owner: node, role: "input", entries: message.entries, uploads: message.uploads,
            readable_text: message.readable_text, seal: true
          )
          raise Refused, result.refusal unless result.accepted?
        end

        def attach_script(node, definition)
          result = ContentBodies::Replace.call(owner: node, role: "input",
            entries: [{ "structured_content" => definition }], seal: true)
          raise Refused, result.refusal unless result.accepted?
        end

        def attached_message(node, prompt, attachments)
          if attachments.blank?
            return ContentBodies::AttachedMessage::Result.new(
              entries: [{ "text" => prompt }], uploads: [], readable_text: nil, refusal: nil
            )
          end
          raise Refused, :attachments_not_authorable if @command.creator.nil?

          ContentBodies::AttachedMessage.compose(
            account: node.account, creating_user: @command.creator, text: prompt, attachments: attachments
          )
        end

        def create_edges(loop_row, compiled, created)
          persisted = persisted_sources(loop_row, compiled)
          compiled.edges.each do |edge|
            from = created[edge["from_key"]] || persisted.fetch(edge["from_key"])
            loop_row.agent_loop_edges.create!(
              from_node: from, to_node: created.fetch(edge["to_key"]), structural: edge.fetch("structural")
            )
          end
        end

        # The one rule: the answer becomes the envelope's end tip iff
        # nothing was designated, or the designation was the starting spine
        # or the starting tip's sole wait.
        def designate_deliverable(loop_row, start, finish, created)
          return unless finish.waits.length == 1

          current = loop_row.deliverable_node&.node_key
          moves = current.nil? || current == start.spine&.key ||
            (start.waits.length == 1 && current == start.waits.sole.key)
          return unless moves

          wait = finish.waits.sole.key
          node = created[wait] || loop_row.agent_loop_nodes.find_by!(node_key: wait)
          loop_row.update!(deliverable_node_id: node.id) unless loop_row.deliverable_node_id == node.id
        end

        # The receipt mirrors the request tree by key — the plan a progress
        # reader renders — beside the keys, the answer and the tokens.
        def receipt_body(loop_row, compiled, created)
          tokens = created.values
            .select { |node| node.resolution_token.present? && !node.observing_task? }
            .to_h { |node| [node.node_key, node.resolution_token] }
          {
            "accepted_task_keys" => created.keys,
            "steps" => compiled.mirror,
            "deliverable_task_key" => loop_row.deliverable_node&.node_key,
            "revision" => loop_row.revision,
            "resolution_tokens" => tokens,
          }
        end

        # Every authored envelope leaves its receipt: it is the plan the
        # progress projection renders. A caller that sent no key gets a
        # minted one nobody holds, so it can never replay.
        def persist_receipt(loop_row, receipt)
          return unless @command.authored

          loop_row.agent_loop_append_receipts.create!(
            idempotency_key: @command.idempotency_key.presence || SecureRandom.uuid,
            request_digest: request_digest,
            response_status: 201,
            response_body: receipt
          )
        end
    end
  end
end
