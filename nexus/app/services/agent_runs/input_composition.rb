module AgentRuns
  # Builds a continuation's request at schedule time under the loop lock;
  # the sealed body is the only record of what the round saw. Segment order
  # is the cache contract: each round prefix-extends the last. What a round
  # SAID is RoundReplay's spelling; this class owns what a round SEES — the
  # replayed prefix, the material it reads, its own input and the steers
  # behind it.
  class InputComposition
    # The bound that binds is the one that stores.
    MAX_COMPOSED_BYTES = Nexus::SizeBounds.fetch(:snapshot_bound)
    CONTEXT_OVERFLOW = :context_overflow
    UNKNOWN_SOURCE = :input_source_unavailable
    MISSING_INPUT = :missing_input

    # A round the user cut short must not look like one that produced
    # nothing. Suppressed when steers are pending: the user's own words are
    # a better explanation than any the kernel could synthesize (codex agrees).
    ABORT_MARKER = <<~TEXT.strip.freeze
      The previous attempt at this step was interrupted on purpose. Any
      tool calls it had started may have partially executed.
    TEXT

    # `replayed_count` is the prefix the source's sealed request supplied
    # — everything after it is this round's TAIL, the only part the usage
    # arm prices. `overshoot` rides the byte wall's refusal so the prune
    # arm can choose; nil on every other one. `steered` is the steer
    # messages the tail closes with — the bytes the landing keeps beside
    # the round (Steers::Landed). `uploads` are the rows the bodies this
    # composition READ bind: the mainline source's sealed request (or,
    # composing from rows, each chain round's input and landed bodies),
    # result bodies, the node's own input and its retained or pending
    # follow-ups. Placement selects from those bindings; the seal never
    # resolves an unbound upload by id. `history_source` carries the same
    # prefix owner into usage checks without selecting its sources again.
    # `said_count` is how many tail elements lead it as what the source
    # round SAID (RoundReplay::Round#said) — the provider's `output_tokens`
    # for that round, which the usage arm counts instead of re-pricing them.
    Result = Data.define(:elements, :refusal, :replayed_count, :overshoot, :steered, :uploads, :history_source,
      :said_count) do
      class << self
        def composed(elements, replayed_count:, steered: [], uploads: [], history_source: nil, said_count: 0) =
          new(elements: elements, refusal: nil, replayed_count: replayed_count, overshoot: nil,
              steered: steered, uploads: uploads, history_source: history_source, said_count: said_count)

        def refused(code, overshoot: nil) =
          new(elements: [], refusal: code, replayed_count: 0, overshoot: overshoot, steered: [], uploads: [],
              history_source: nil, said_count: 0)
      end

      def composed? = refusal.nil?
      def tail = elements.drop(replayed_count)
    end

    class << self
      def call(...) = new(...).call

      # The rows a node continues from, in its read order.
      def sources_for(node) = Sources.new(node).call

      # The round a node continues: its first model source — never a race's
      # loser, since no continuation reads across a race — the one chain
      # step the repeat brake and the delivered envelope's root share.
      def source_round(node) = sources_for(node).find(&:model_task?)

      # History readers need the material a round consumed as well as its
      # answer. Read explicit sources in one batch; the ordinary mainline/fan
      # case has no delivered material and needs no dependency walk or body.
      def material_by_round(rounds, readers: readers_by_round(rounds))
        deliveries = delivered_sources_by_round(rounds, readers: readers)
        preload_material(deliveries.values.flatten(1).map(&:first))
        deliveries.transform_values { |sources| material_messages(sources) }
      end

      def material_messages(sources)
        sources.map do |tip, boundary|
          Nexus::TextInputMessage.new(role: "user", parts: [Nexus::TextInputPart.new(
            type: Nexus::InputParts::TEXT, text: TaskResultEnvelope.for(tip, boundary: boundary)
          )])
        end
      end

      # Keep source provenance for the summarizer: delivered tool output
      # is a pointer there, while an ask answer or model result is text.
      # The stages every reader and tip sit behind load once per loop.
      def delivered_sources_by_round(rounds, readers: readers_by_round(rounds))
        owners = readers.values.group_by(&:agent_run_id).transform_values do |group|
          ExpansionOwnership.owners(group.first.agent_run, group.flat_map(&:owned_keys))
        end
        readers.transform_values { |reader| reader.delivered_sources(owners.fetch(reader.agent_run_id)) }
      end

      # A summary cuts the source round out of history, but its fan is
      # first read here. Keep those pairs at their consumer, in the same
      # spelling as the live request, without the replaced round's words.
      def compacted_pairs_by_round(readers, replay: nil, traces: {}, cleared_ids: [])
        compacted = readers.select { |_, reader| reader.compacted_fan.any? }
        associations = { tool_calls_body: { content_body_entries: :content_fragment } }
        if RoundReplay.native_replay?(replay)
          associations[:reasoning_trace_body] = { content_body_entries: :content_fragment }
        end
        ActiveRecord::Associations::Preloader.new(records: compacted.values.map(&:compacted_source),
          associations: associations).call
        RoundReplay.preload([], calls: compacted.except(*cleared_ids).values.flat_map do |reader|
          RoundReplay.result_nodes(reader.compacted_fan.values, tips_by_call_key: reader.substituted_tips)
        end)
        compacted.to_h do |id, reader|
          [id, reader.compacted_pairs(replay: replay, trace: traces[id], cleared: cleared_ids.include?(id))]
        end
      end

      # Each round's composition over the sources it read, for the rounds
      # that read something beside their mainline — what was delivered to it
      # and the tips its paired calls answered with. An unminted round has
      # not consumed its sources yet.
      def readers_by_round(rounds)
        rounds = rounds.select { |round| round.selected_model_invocation_id.present? }
        return {} if rounds.empty?

        scopes = rounds.group_by(&:agent_run_id).map do |loop_id, rows|
          keys = rows.flat_map { |row| Array(row.input_from_node_keys) + Array(row.result_from_node_keys) }.uniq
          AgentRunTask.where(agent_run_id: loop_id, node_key: keys)
        end
        sources = scopes.reduce(&:or).index_by { |row| [row.agent_run_id, row.node_key] }
        expanded = {}
        rounds.filter_map do |round|
          inputs = Array(round.input_from_node_keys).map { |key| sources.fetch([round.agent_run_id, key]) }
          results = TaskResultProjection.readings(
            Array(round.result_from_node_keys).map { |key| sources.fetch([round.agent_run_id, key]) }, expanded
          )
          model_source = inputs.find(&:model_task?)
          next if round.compaction.to_h[AgentRunTasks::ModelTask::SUMMARY_SOURCE].blank? &&
            unpaired(inputs, model_source: model_source).empty? &&
            results.all? { |tip| replayed?(tip, model_source: model_source) }

          [round.id, new(node: round, input: nil, sources: inputs, result_sources: results)]
        end.to_h
      end

      def preload_material(sources)
        delivered = sources.uniq(&:id)
        ActiveRecord::Associations::Preloader.new(records: delivered, associations: :output_body).call
        bodies = delivered.filter_map(&:output_body).select { |body| body.readable_text.nil? }
        ActiveRecord::Associations::Preloader.new(
          records: bodies, associations: { content_body_entries: :content_fragment }
        ).call
      end

      def unpaired(sources, model_source:)
        sources.select do |source|
          case source.task_kind
          when "await_task", "delegation_task", "join_task" then true
          when "tool_task" then source.tool_call_id.blank?
          when "model_task" then !replayed?(source, model_source: model_source)
          else false
          end
        end
      end

      # A completed model source is replayed as history, so it is neither
      # material nor a result envelope: any `results` entry naming the round
      # the reader continues — a fan-in reducer's first branch, a race's
      # selected model winner — reaches it once, as history. The rule is
      # the source's alone: a model its own replayed request carries
      # further back is still delivered as an envelope.
      def replayed?(source, model_source:)
        source.model_task? && source.id == model_source&.id && source.status == "completed"
      end
    end

    # A declared source that vanished between the append door's check and
    # this schedule is not a composition to guess at.
    class MissingSource < StandardError; end

    # `input` is the node's own decoded input body: a String (the authored
    # prompt, one user message), an Array of wire elements (round one of a
    # loop-backed turn, the assembled request sent as sealed), or nil for
    # a node whose sources are its whole question. `replay` is the
    # assembled-lane's Replay value (mode + resolved target); nil disables
    # the native rung, which is what a lane without reasoning-replay
    # capability means. `steers` are the ROWS landing in this round,
    # rendered here through the speaker envelope by their author — a
    # peer's steer wrapped, the person's bare — each its own final user
    # message, in queue order.
    def initialize(node:, input:, replay: nil, steers: [], sources: nil, result_sources: nil)
      @node = node
      @input = input
      @replay = replay
      @steers = Array(steers)
      @read_sources = sources
      @read_results = result_sources
    end

    def call
      # Measured after the steers, so the bound covers what is actually
      # sent and a steered round overflows typed rather than failing at seal.
      pending = pending_steer_messages
      normalized_steers = ModelSelection::Workloads.normalize_input(
        workload: "text_generation", input: pending
      ) unless pending.empty?
      steered = landed_steer_messages + (normalized_steers&.value || pending)
      elements = history + current_input + steered
      total = measure(elements)
      if total > MAX_COMPOSED_BYTES
        return Result.refused(CONTEXT_OVERFLOW,
          overshoot: Conversations::Compaction::Overshoot.bytes(total - MAX_COMPOSED_BYTES))
      end
      # A request whose last word is the assistant's own is not a question:
      # one wire refuses it pre-IO and the rest answer nothing useful.
      return Result.refused(MISSING_INPUT) if assistant_last?(elements)

      # Preserve the composition walls' precedence over a new input refusal.
      # Prior requests and kernel-authored segments already have their own writers.
      return Result.refused(normalized_steers.refusal) if normalized_steers&.refusal
      refusal = ModelSelection::Workloads::Input.message_presence_refusal(elements)
      return Result.refused(refusal) if refusal

      Result.composed(elements, replayed_count: model_source ? prior_request.length : 0, steered: steered,
        uploads: bound_uploads, history_source: model_source, said_count: @said_count || 0)
    rescue MissingSource
      Result.refused(UNKNOWN_SOURCE)
    end

    # The summary, authored input and steers have their own readers. These
    # are just the delivered answers/results between the replay and that tail.
    def delivered_material
      self.class.material_messages(delivered_sources)
    end

    # Each delivered tip with whether the read crosses a stage's result
    # boundary: the tip sits behind a stage — its nearest, a stage's own
    # value included — that the reader is not inside. A step reading a
    # sibling inside the same stage keeps the sibling's brief; the stage's
    # value read from outside it keeps none. `owners` is the batch's load.
    def delivered_sources(owners = nil)
      return [] if delivered_tips.empty?

      owners ||= ExpansionOwnership.owners(agent_run, owned_keys)
      inside = owners.fetch(@node.node_key, [])
      delivered_tips.map do |tip|
        chain = owners[tip.node_key]
        [tip, !chain.nil? && !inside.include?(chain.first)]
      end
    end

    # What this round reads beside its mainline: its unpaired sources and the
    # results it names, a result the mainline's history replays excluded.
    def delivered_tips
      @delivered_tips ||= begin
        paired = paired_sources.map(&:id).to_set
        results = result_sources.reject do |tip|
          paired.include?(tip.id) || self.class.replayed?(tip, model_source: model_source)
        end
        substituted = (substituted_tips.values + results).map(&:id).to_set
        ordinary = unpaired_sources.reject { |source| substituted.include?(source.id) }
        ordinary + results
      end
    end

    def compacted_source = summary ? raw_model_source : nil
    def compacted_fan = compacted_source ? fan_by_call_id : {}

    def compacted_pairs(replay: @replay, trace: nil, cleared: false)
      return nil unless compacted_source && compacted_fan.any?

      RoundReplay.pairs(compacted_source, fan_by_call_id: compacted_fan,
        tips_by_call_key: substituted_tips, replay: replay, trace: trace, cleared: cleared)
    end

    # The actual results that paired calls consume, preserving provenance
    # for summary pointers and excluding a launch acknowledgement replaced
    # by a waited result. A result named in both read slots still rides once.
    def paired_sources
      return [] unless raw_model_source

      fan_by_call_id.values.map { |call| substituted_tips.fetch([call.agent_run_id, call.node_key], call) }
    end

    def agent_run = @node.agent_run
    def agent_run_id = @node.agent_run_id

    # The rows whose stages decide a boundary: the reader and every tip.
    def owned_keys = [@node, *delivered_tips].map(&:node_key)

    # The `task`/`spawn`/`wait` calls of the mainline source whose tip is
    # among this node's sources and settled: keyed by the call, the tip it
    # answers with — a task's branch round, a waited spawn's AWAIT, a
    # wait's observing await (an await is never `model_task?`, so the filter
    # admits them; an ask's await never matches a paired call).
    def substituted_tips
      return @substituted_tips if defined?(@substituted_tips)

      calls = fan_by_call_id.values.select { |call| BranchTools::PAIRED_VERBS.include?(call.tool_name) }
        .index_by(&:node_key)
      tips = unpaired_sources.select { |tip| (tip.model_task? || tip.await? || tip.delegation? || tip.tool_call?) && tip.terminal? }
      @substituted_tips = calls.empty? ? {} : tips.filter_map do |tip|
        key = TaskResultEnvelope.call_key(tip)
        [[tip.agent_run_id, key], tip] if calls.key?(key)
      end.to_h
    end

    private

      # A repaired round reads its summary instead of consumed history: this is
      # where compaction breaks the chain. Only a summary that ARRIVED cuts
      # (the node's own predicate, shared with every reader of the mark).
      def summary
        return @summary if defined?(@summary)

        @summary = @node.arrived_summary
      end

      def raw_sources = @raw_sources ||= Sources.new(@node, sources: @read_sources).call
      def raw_model_source = @raw_model_source ||= raw_sources.find(&:model_task?)

      # Selected outputs are ordered material, never a history candidate or
      # race-selected implicit input. A compaction cannot replace these slots.
      # A race named here reads what it selected (`TaskResultProjection.referenced`);
      # the batch history readers hand that expansion in as `@read_results`.
      def result_sources
        @result_sources ||= begin
          # A refused model has no sealed request to preserve its selected
          # material. Recover it just as Sources recovers its ordinary inputs.
          recovered = raw_sources.select do |source|
            source.model_task? && source.failure? && source.selected_model_invocation_id.nil?
          end.flat_map { |source| Array(source.result_from_node_keys) }
          selected = Array(@node.result_from_node_keys)
          keys = (recovered - selected).uniq + selected
          if @read_results && recovered.empty?
            @read_results
          else
            rows = @node.agent_run.agent_run_tasks.where(node_key: keys).index_by(&:node_key)
            TaskResultProjection.readings(keys.map { |key| rows[key] || raise(MissingSource) })
          end
        end
      end

      # The mainline is the first model source, the only one replayed as
      # history; the rest are read material, since two histories have no
      # stable prefix. A summary has no mainline: replaying it would put the history back.
      def model_source
        return nil if summary

        raw_model_source
      end

      # Scoped to this round's tool tasks: a call id reused by a later
      # round must never reach back for an older result.
      def fan_by_call_id
        raw_sources.select { |s| s.tool_call? && s.tool_call_id.present? }
          .index_by(&:tool_call_id)
      end

      # SEGMENT A: what the source round saw, verbatim; SEGMENT B: what it
      # said, in the one renderer's spelling. A PRUNED round composes
      # segment A from rows instead, results before its mark cleared; its
      # own sealed body is then the prefix the next continuation replays —
      # the one licensed bust, once per wall.
      def history
        return [] if model_source.nil?
        return rows_history if @node.pruned_before

        round = RoundReplay.call(model_source, fan_by_call_id: fan_by_call_id, replay: @replay,
          tips_by_call_key: substituted_tips)
        @said_count = round.said.length
        prior_request + round.elements
      end

      # The chain back to the last cut, each round as what it READ — the
      # cut's summary when the oldest is a repaired round, then its own
      # input body, then the steers that landed in it (their own body) —
      # and what it SAID through the one renderer, blocking `task` calls
      # paired with their branches' last words as the next turn's history
      # pairs them. Delivered answers and wake results stay before the
      # round that read them, just as they do in later-turn history.
      def rows_history
        rounds = chain_rounds
        fans = chain_fans
        tips = chain_paired_tips
        landed = history_steer_bodies.transform_values { |body| Steers::Landed.messages_of(body) }
        material = self.class.material_by_round(rounds, readers: history_readers)
        cleared = cleared_count
        paired = self.class.compacted_pairs_by_round(history_readers, replay: @replay,
          cleared_ids: rounds.first(cleared).map(&:id))
        RoundReplay.preload(rounds, calls: result_calls)
        ActiveRecord::Associations::Preloader.new(
          records: rounds,
          associations: { input_body: [{ content_body_entries: :content_fragment }, :content_uploads] }
        ).call
        rounds.each_with_index.flat_map do |round, index|
          read_by(round, index.zero?, material: material.fetch(round.id, []), paired: paired[round.id]) +
            landed.fetch(round.id, []) +
            RoundReplay.call(round, fan_by_call_id: fans.fetch(round.id, {}), replay: @replay,
              tips_by_call_key: tips, cleared: index < cleared).elements
        end
      end

      def read_by(round, oldest, material: [], paired: nil)
        summary = oldest ? round.arrived_summary : nil
        lead = summary ? [user_message(summary_material_of(summary))] : []
        lead + pair_elements(paired) + material + input_elements(round.input_value)
      end

      # The source's sealed request is the only faithful record —
      # reconstructing it from the node's authored prompt would drop
      # everything spliced into it.
      def prior_request
        @prior_request ||= begin
          body = model_source.invocation_body("request")
          restored = body && Nexus::InputEntries.from(
            entries: body.content_body_entries.map { |entry| entry.content_fragment.payload },
            workload: "text_generation"
          )
          case restored
          when Array then restored
          when nil then []
          else [user_message(restored.to_s)]
          end
        end
      end

      # Every unpaired source is a DELIVERED tip — an await's answer, a
      # tool's output, a branch's last word — rendered as one user message
      # in the kernel's envelope, UNCONDITIONALLY: a tip with nothing to say
      # says so rather than vanishing. This task's OWN authored prompt
      # closes the list.
      def current_input
        messages = material + (abort_marked? ? [user_message(ABORT_MARKER)] : [])
        messages + own_input
      end

      # A summary is not a delivery: it stands in for history and reads as
      # plain material under the kernel's re-read frame. A tip a `task`
      # call already answered with is not rendered twice.
      def material
        (summary ? [user_message(summary_material)] : []) + pair_elements(compacted_pairs) + delivered_material
      end

      def pair_elements(paired)
        paired ? paired.elements : []
      end

      def own_input = input_elements(@input)

      # The joins of every body this composition rendered a part of, in read order,
      # distinct: the prefix's (the mainline source's sealed request, or each chain
      # round's own input when composing from rows), the paired results' output
      # bodies (the captures the round's picture message names), then this node's own
      # input and landed follow-ups (a standalone queue can carry pictures).
      # Placement keeps only the rows it placed, so a result's non-media capture
      # binds nothing.
      def bound_uploads
        bodies = prefix_bodies + result_bodies + [@node.input_body, retained_steer_body] + steer_bodies
        bodies.compact.flat_map { |body| body.content_uploads.to_a }.uniq(&:public_id)
      end

      def prefix_bodies
        return [] if model_source.nil?
        return [model_source.invocation_body("request")] unless @node.pruned_before

        chain_rounds.map(&:input_body) + history_steer_bodies.values
      end

      # The output bodies of every result the history PAIRS: the mainline
      # source's own fan, or each chain round's when composing from rows —
      # the same fans `history` renders.
      def result_bodies
        result_calls.filter_map(&:output_body)
      end

      # Cleared results render no captures, so neither rendering nor binding
      # needs their bodies. Both readers reuse the same fan records.
      def result_calls
        if model_source && @node.pruned_before
          kept = chain_rounds.drop(cleared_count).map(&:id)
          calls = chain_fans.slice(*kept).values.flat_map(&:values)
          RoundReplay.result_nodes(calls, tips_by_call_key: chain_paired_tips) +
            history_readers.slice(*kept).values.flat_map do |reader|
              RoundReplay.result_nodes(reader.compacted_fan.values, tips_by_call_key: reader.substituted_tips)
            end
        else
          RoundReplay.result_nodes(fan_by_call_id.values, tips_by_call_key: substituted_tips)
        end
      end

      def chain_fans = @chain_fans ||= RoundReplay.fans_of(chain_rounds)

      def chain_paired_tips = @chain_paired_tips ||= BranchClosure.tips_by_call_key(chain_fans.values.flat_map(&:values))

      def cleared_count = Conversations::Compaction::Prune.cleared_count(chain_rounds, @node.pruned_before)

      def chain_rounds = @chain_rounds ||= Conversations::Compaction::Serialize.chain(@node)

      def history_steer_bodies = @history_steer_bodies ||= Steers::Landed.bodies_by_round(chain_rounds)

      def history_readers = @history_readers ||= self.class.readers_by_round(chain_rounds)

      # A decoded body is dispatched whole: a list is sent verbatim, a text
      # closes as one user message, absence adds nothing.
      def input_elements(value)
        case value
        when Array then value
        when String then value.present? ? [user_message(value)] : []
        when nil then []
        else raise ArgumentError, "undecodable node input: #{value.class}"
        end
      end

      # An await's answer, a hand-spliced tool source (no pairing key, so
      # no call) and every model source past the mainline are input the model
      # reads, not results to pair — in the node's own read order. A failed
      # or canceled history source also supplies its result envelope: replay
      # alone does not explain why the work stopped, even if it produced text.
      def unpaired_sources
        self.class.unpaired(raw_sources, model_source: raw_model_source)
      end

      def landed_steer_messages
        # A retry re-mints this same round after its input rows were consumed.
        # Keep its own landed tail; the source round's is already in history.
        retained_steer_body ? Steers::Landed.messages_of(retained_steer_body) : []
      end

      def pending_steer_messages
        @steers.zip(steer_bodies).map do |steer, body|
          if body.content_uploads.empty?
            user_message(Conversations::ContextAssembly::SpeakerEnvelope.for_input(steer))
          else
            # The queue can carry pictures even though an explicit steer
            # cannot. Keep their occurrence order and wrap only the words.
            Nexus::TextInputMessage.new(role: "user", parts: body.parts.map do |part|
              part.type == Nexus::InputParts::TEXT ?
                part.with(text: Conversations::ContextAssembly::SpeakerEnvelope.for_input(steer, part.text)) : part
            end)
          end
        end
      end

      def steer_bodies = @steer_bodies ||= @steers.map(&:content_body)

      def retained_steer_body
        return @retained_steer_body if defined?(@retained_steer_body)

        @retained_steer_body =
          Steers::Landed.bodies_by_round([@node])[@node.id] if @node.execution_generation.positive?
      end

      def assistant_last?(elements)
        case elements.last
        when Nexus::TextInputMessage then elements.last.role == "assistant"
        else false
        end
      end

      # Derived, never stored: this node is on a fresh generation and the
      # attempt it replaces was terminalized as `interrupted`. Suppressed
      # when the user's own directive is about to land.
      def abort_marked?
        return false if @steers.any? || @node.execution_generation.zero?

        ModelInvocation
          .where(internal_creation_key:
            "agent_run_task:#{@node.id}:#{@node.execution_generation - 1}")
          .where(status: "canceled", failure_reason_key: "interrupted")
          .exists?
      end

      # Per-entry accumulation, never a whole-list render: a multi-MiB
      # composition must not be materialized as one string under the loop
      # lock just to measure it. The whole total, so the wall can say by
      # how much (the prune arm's choice) — THE ONE MEASURE the seal and
      # the preview read (`ContentBodies::Measure`).
      def measure(elements)
        ContentBodies::Measure.call(Nexus::InputEntries.for(elements)).bytes
      rescue Nexus::CanonicalJson::UnsupportedText, Nexus::CanonicalJson::UnsupportedNumber
        # Unstorable is not "too large" — the storage guard at the mint
        # answers that with its own typed refusal.
        0
      end

      def summary_material = summary_material_of(summary)

      def summary_material_of(node)
        "#{Conversations::Compaction::REREAD_RULE}\n\n" \
          "#{node.content_bodies.find_by(role: "output").effective_text}"
      end

      def user_message(text)
        Nexus::TextInputMessage.new(
          role: "user",
          parts: [Nexus::TextInputPart.new(type: Nexus::InputParts::TEXT, text: text)]
        )
      end
  end
end
