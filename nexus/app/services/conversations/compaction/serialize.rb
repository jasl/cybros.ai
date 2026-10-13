module Conversations
  module Compaction
    # The summarizer reads a rendering, since this runs exactly when the
    # request does not fit. ONE serializer over ENTRIES (turn > variant >
    # entries; a loop-backed turn's rounds ARE entries), with two producers
    # — a loop's mainline chain, a timeline's assembly window — and one tail
    # rule the prune arm shares, each arm in its own unit. The tail is cut
    # on entry boundaries, never between a call and its result. A reply
    # turn's SEED — the words that opened it — is the `User:` of its round
    # one under both producers, folded into that entry so the rows and
    # entries stay index-aligned; the seed and a user-role turn's content
    # read through the speaker envelope by their turn, and a round's landed
    # steers follow its `User:` — the summarizer reads a peer's row as a
    # peer's. A PICTURE IS A POINTER: a seed's, a message turn's or an
    # authored prompt's attachments render as one `[Attachment: …]` line
    # each after the words — the index line's grammar with the summary's
    # reason — read through the same `ContentBody#upload_parts` history
    # reads, so the rendering and the wire agree on which pictures a turn
    # carried; the summarizer could not see a picture in any case, and a
    # described picture would be a paraphrased value.
    module Serialize
      # The rendering the summarizer reads is bounded by the same wall
      # the composition hit — otherwise the repair cannot fit either.
      MAX_BYTES = 512.kilobytes
      # The tail is rendered under its own header, not carried past the
      # summary, and bounded as a fraction as well as absolutely: an
      # absolute cap alone would keep a small history verbatim and shrink nothing.
      TAIL_BYTES = 80.kilobytes
      TAIL_FRACTION = 0.25
      # What a cleared result costs the request instead of its body.
      CLEARED_BYTES = AgentRuns::RoundReplay::Pairing::CLEARED.bytesize
      SUMMARY_LEAD = "Summary of earlier work:".freeze

      # Every drop on this path is announced (`Nexus::Elision`).

      # THE NAMES THE MODEL SAW: a summary's NEXT STEPS name tools, and a
      # summarizer told none wrote `execute_command` to a loop that had
      # declared `bash`. The declared set leads the request in its
      # model-facing spelling; INSTRUCTIONS stays one text.
      TOOLS_HEADER = "The tools the agent has:".freeze
      HEADER = "Here is the transcript to compact.".freeze
      TAIL_HEADER = <<~TEXT.strip.freeze
        The following is the most recent work. Summarize it too, but keep
        its specifics: it is what the agent is in the middle of.
      TEXT

      # PRODUCER 1'S ROWS BESIDE ITS RENDERING (one tail two arms): ONE RULE
      # — a quarter of the total, TAIL_BYTES at most, newest first, the
      # oldest never joins — applied in each arm's own UNIT. The summarizer
      # cuts the rendering it reads; the prune arm cuts REQUEST bytes, what
      # each round's answer, calls and results cost the composed request,
      # because that is what a prune clears. Cut on the rendering, where a 46
      # KB result is a 300-byte pointer, "80 KB" kept 15–29 whole results
      # verbatim on every Long and the post-prune floor ratcheted. `bytes` is
      # the stored size of every output body in the chain, keyed by row — one
      # SQL sum, never a body load; a rendering carries pointers.
      LoopHistory = Data.define(:rounds, :entries, :fans, :bytes, :current_call_ids, :compacted_readers, :receipts) do
        def tail_index = Serialize.tail_index(request_sizes)

        # The fan in the target's read slots has not yet had its first
        # consumption there. It is required even when the ordinary tail
        # budget keeps no round; only earlier consumed results may clear.
        def prune_index
          current = rounds.index { |round| fan_of(round).any? { |tool| current_call_ids.include?(tool.id) } }
          [tail_index, current || rounds.length].min
        end

        def prune_round = rounds[prune_index]

        # What each round costs the composed request, index-aligned with
        # `rounds`: its answer, its calls' arguments and their results —
        # the placeholder's bytes for a result an earlier prune cleared.
        def request_sizes
          cleared = Prune.cleared_count(rounds)
          rounds.each_with_index.map do |round, index|
            bytes.fetch(round.id, 0) + fan_of(round).sum do |tool|
              receipt = receipt_for(round, tool)
              output_size = receipt ? receipt.payload.fetch("output").bytesize : bytes.fetch(tool.id, 0)
              Serialize.arguments_bytes(tool) + (index < cleared && !receipt && clears?(tool) ? CLEARED_BYTES : output_size)
            end
          end
        end

        # Σ over the results before the tail that an earlier prune has not cleared
        # of (bytes − CLEARED_BYTES): what a prune FREES on the wire — each cleared
        # call still costs its placeholder (`request_sizes` charges the same) — so a
        # prune the arm chooses always brings the round under the wall. A call
        # that settled without a result is never cleared, so it frees nothing.
        def prunable_bytes
          rounds[Prune.cleared_count(rounds)...prune_index].to_a.sum do |round|
            fan_of(round).select { |tool| !receipt_for(round, tool) && clears?(tool) }
              .sum { |tool| bytes.fetch(tool.id, 0) - CLEARED_BYTES }
          end
        end

        # Count the same paired output a round reads, including a waited
        # branch's result and error envelopes, before and after the clear —
        # each rendered by the one pairing, so what a prune keeps is counted
        # on both sides. Only token walls pay for these bodies; byte walls
        # use the stored sizes above.
        def prunable_tokens(profile)
          candidates = rounds[Prune.cleared_count(rounds)...prune_index].to_a
          calls = candidates.flat_map { |round| fan_of(round) }
          AgentRuns::RoundReplay.preload(candidates, calls: calls)
          tips = AgentRuns::BranchClosure.tips_by_call_key(calls)
          before, after = [false, true].map do |cleared|
            consumed = AgentRuns::InputComposition.compacted_pairs_by_round(compacted_readers.slice(*candidates.map(&:id)),
              cleared_ids: (cleared ? candidates.map(&:id) : []))
            results = candidates.flat_map do |round|
              Array(consumed[round.id]&.result_items) + AgentRuns::RoundReplay.call(round, fan_by_call_id: fans.fetch(round.id, {}),
                tips_by_call_key: tips, cleared: cleared, receipts: receipts.fetch(round.id, {})).result_items
            end
            ModelRequests::TokenCount.count(profile: profile, segments: Nexus::ModelRequestInput.text_segments(results))
          end
          before.tokens - after.tokens if before.counted? && after.counted?
        end

        private

          def fan_of(round)
            reader = compacted_readers[round.id]
            fans.fetch(round.id, {}).values + (reader ? reader.compacted_fan.values : [])
          end

          def clears?(tool) = AgentRuns::RoundReplay::Pairing.clears?(tool)

          def receipt_for(round, tool)
            reader = compacted_readers[round.id]
            paired = reader && reader.compacted_fan.value?(tool) ? reader.tool_receipts : receipts.fetch(round.id, {})
            paired[tool.tool_call_id]
          end
      end

      module_function

      # What the summarizer is asked to read: the declared names when the
      # host has any, the transcript, the tail.
      def request(older, tail, tools: nil)
        names = Array(tools)
        [
          ("#{TOOLS_HEADER}\n#{names.join(", ")}" if names.any?),
          ("#{HEADER}\n\n#{older}" if older.present?),
          ("#{TAIL_HEADER}\n\n#{tail}" if tail.present?),
        ].compact.join("\n\n")
      end

      # Returns [older_text, retained_tail_text] over rendered entries.
      # Either may be empty: a history that is all tail needs no summary,
      # and a history with no entries at all is not compactable. `room` is
      # the older section's byte budget — the storage wall by default, or
      # less when the arm is fitting the request to the reader's window.
      def call(entries, room: MAX_BYTES)
        return ["", ""] if entries.empty?

        cut = tail_index(entries.map(&:bytesize))
        [fit(entries.first(cut), room), entries.drop(cut).join("\n\n")]
      end

      # ONE tail rule, two arms, over SIZES so each arm brings its own
      # unit — the summarizer its rendered entries' bytes, the prune arm
      # its rounds' request bytes: the index of the first item that joins
      # the keep-recent tail, `sizes.length` when none. The oldest never
      # joins — there is always something to summarize or prune — and the
      # tail fills newest-first inside its budget.
      def tail_index(sizes)
        budget = (sizes.sum * TAIL_FRACTION).clamp(..TAIL_BYTES)
        bytes = 0
        index = sizes.length
        while index > 1 && bytes + sizes[index - 1] <= budget
          bytes += sizes[index - 1]
          index -= 1
        end
        index
      end

      # Drops whole entries, oldest first, so the count is honest and no
      # entry begins mid-sentence; the byte clamp underneath is for a
      # single entry past the budget.
      def fit(entries, room = MAX_BYTES) = Nexus::Elision.fit(entries, room, noun: "round")

      # PRODUCER 1 — a round's history: the mainline oldest first, through
      # the declared sources the composer reads, one entry per round that
      # rendered anything, the rows kept beside the entries in step.
      def loop_history(node)
        rounds = chain(node)
        preload_rounds(rounds)
        fans = AgentRuns::RoundReplay.fans_of(rounds)
        receipts = AgentRuns::Steers::ToolReceipts.by_source(rounds)
        current_receipts = AgentRuns::Steers::ToolReceipts.for_consumer(node)
        source = AgentRuns::InputComposition.source_round(node)
        receipts[source.id] = current_receipts if source && current_receipts.any?
        steers = AgentRuns::Steers::Landed.texts_by_round(rounds)
        readers = AgentRuns::InputComposition.readers_by_round(rounds)
        compacted_readers = readers.select { |_, reader| reader.compacted_fan.any? }
        material = delivered_material(rounds, readers: readers)
        bytes = output_bytes(rounds + fans.values.flat_map(&:values) +
          compacted_readers.values.flat_map { |reader| reader.compacted_fan.values })
        seed = seed_of(node.agent_run.conversation_turn_variant) if rounds.any? { |round| seed_model_task?(round) }
        rendered = rounds.filter_map do |round|
          entry = render_round(round, fans.fetch(round.id, {}), prompt: (seed if seed_model_task?(round)),
            steers: steers.fetch(round.id, []), material: material.fetch(round.id, []), bytes: bytes,
            receipts: receipts.fetch(round.id, {}))
          [round, entry] if entry
        end
        current_call_ids = AgentRuns::InputComposition.sources_for(node).select(&:tool_call?).map(&:id).to_set
        LoopHistory.new(rounds: rendered.map(&:first), entries: rendered.map(&:last), fans: fans, bytes: bytes,
          current_call_ids: current_call_ids, compacted_readers: compacted_readers, receipts: receipts)
      end

      # THE STORED SIZES the rows' output bodies carry: one SQL sum for the
      # whole chain, never a body load.
      def output_bytes(nodes) = ContentBody.output_bytes_by_node(nodes.map(&:id))

      # The bytes a call's arguments cost the request — the rows carry them.
      def arguments_bytes(tool) = tool.arguments_json.bytesize

      def loop_entries(node) = loop_history(node).entries

      # PRODUCER 2 — a timeline's assembly window, each turn by its KIND:
      # a summary as its content under the lead, a loop-backed reply as
      # its mainline rounds after its in-turn cut, every other turn as its
      # content in its role. ONE batched read for the window.
      def timeline_entries(conversation)
        turns = window(conversation)
        timeline_turn_entries(turns, turns.to_h { |turn| [turn.id, turn.active_variant_id] })
      end

      # A side freezes the currently executing candidate, which can differ
      # from the displayed answer during regeneration. Keep its summary on
      # this same pointer renderer while its source rows still exist.
      def reference_entries(turn:, variant:)
        timeline_turn_entries([turn], { turn.id => variant.id })
      end

      def timeline_turn_entries(turns, variants)
        variant_ids = variants.values.compact
        bodies = ContentBody.preload_for_render(
          ContentBody.where(conversation_turn_variant_id: variant_ids, role: %w[content prompt reference])
        ).group_by(&:role)
          .transform_values { |rows| rows.index_by(&:conversation_turn_variant_id) }
        contents = bodies.fetch("content", {})
        prompts = bodies.fetch("prompt", {})
        references = bodies.fetch(ReferenceSnapshot::ROLE, {})
        loops = AgentRun.where(conversation_turn_variant_id: variant_ids)
          .index_by(&:conversation_turn_variant_id)
        rounds = mainline_rounds(loops.values).transform_values { |rows| kept_rounds(rows) }
        preload_rounds(rounds.values.flatten)
        fans = AgentRuns::RoundReplay.fans_of(rounds.values.flatten)
        receipts = AgentRuns::Steers::ToolReceipts.by_source(rounds.values.flatten)
        steers = AgentRuns::Steers::Landed.texts_by_round(rounds.values.flatten)
        material = delivered_material(rounds.values.flatten)
        bytes = output_bytes(fans.values.flat_map(&:values))
        ActiveRecord::Associations::Preloader.new(
          records: turns, associations: [{ speaker: :user }, :conversation, { answering_user: :steward }]
        ).call
        turns.flat_map do |turn|
          variant_id = variants.fetch(turn.id)
          agent_run = loops[variant_id]
          seed = seed_text(turn, prompts[variant_id])
          if references[variant_id]
            ReferenceSnapshot.summary_entries(references.fetch(variant_id))
          elsif turn.compaction_summary? || agent_run.nil?
            Array(render_turn(turn, content_text(turn, contents[variant_id]), seed: seed))
          else
            rounds.fetch(agent_run.id, []).filter_map do |round|
              render_round(round, fans.fetch(round.id, {}), prompt: (seed if seed_model_task?(round)),
                steers: steers.fetch(round.id, []), material: material.fetch(round.id, []), bytes: bytes,
                receipts: receipts.fetch(round.id, {}))
            end
          end
        end
      end

      # Round one of a conversation-backed loop opens with the turn's seed
      # — unless a summary leads it, which stands in for the seed too
      # (`ChatHistory#round_segments`' rule).
      def seed_model_task?(round)
        round.node_key == Inputs::ApplyNext::SEED_ROUND_KEY && !repaired?(round)
      end

      def seed_of(variant)
        return nil if variant.nil?

        seed_text(variant.conversation_turn, variant.content_bodies.find_by(role: "prompt"))
      end

      # THE SEED AS THE SUMMARIZER READS IT: the words through the speaker
      # envelope by the turn, then each picture as a pointer — the shape the
      # door wrote (words, then pictures), which is the entry order. A seed
      # with no words (a picture alone) is its pointers; a raw seed (no
      # words at all) renders nothing, pictures included — raw is never
      # enriched, as history reads it (`ChatHistory#seed_segment`).
      def seed_text(turn, body)
        words = body&.readable_text
        return nil if words.nil?

        with_pointers(ContextAssembly::SpeakerEnvelope.for_turn(turn, words), body)
      end

      # A turn's content the same way: a user-role turn's words in the
      # envelope, then its pictures; a summary's and an assistant's carry
      # none (the join is the message body's).
      def content_text(turn, body)
        return nil if body.nil?

        text = body.effective_text
        if turn.role == "user" && !turn.compaction_summary?
          text = ContextAssembly::SpeakerEnvelope.for_turn(turn, text)
        end
        with_pointers(text, body)
      end

      # The words, then one pointer line per picture in entry order — the
      # index line's grammar with the summary's reason; the size is the
      # blob row's, never a load.
      def with_pointers(text, body)
        lines = body.upload_parts.map do |upload|
          ContextAssembly::AttachmentLine.render(upload, ContextAssembly::AttachmentLine::NOT_CARRIED)
        end
        [text.presence, *lines].compact.join("\n").presence
      end

      # The same cut and window assembly reads, from the same code:
      # anything older was never sent, and summarizing it would grow the
      # repair's cost without bound on the conversations that need it.
      def window(conversation)
        conversation.timeline.entries(
          surface: :assembly,
          from_position: ContextAssembly::ChatHistory.compaction_cut(conversation),
          limit: ContextAssembly::ChatHistory::CANDIDATE_LIMIT,
          newest: true
        ).map(&:turn)
      end

      # The first source defines order, including inserted immediate steers.
      def mainline_rounds(loops)
        return {} if loops.empty?

        AgentRunTasks::ModelTask
          .where(agent_run_id: loops.map(&:id), continuation_source: AgentRuns::Tasks::Compile::ROUND)
          .order(:id)
          .group_by(&:agent_run_id)
          .transform_values { |rows| AgentRuns::InputComposition.order_rounds(rows) }
      end

      # The in-turn cut (`ChatHistory#round_segments`' rule): the newest
      # round whose summary ARRIVED leads, carrying that summary, and the
      # rounds it replaced leave history.
      def kept_rounds(rounds)
        cut = rounds.rindex { |round| repaired?(round) }
        cut ? rounds.drop(cut) : rounds
      end

      # A plain turn is ONE entry — its seed then its content (already
      # rendered by `content_text`) — so the tail rule keeps cutting on
      # turn boundaries.
      def render_turn(turn, text, seed: nil)
        return "#{SUMMARY_LEAD}\n#{text}" if turn.compaction_summary? && text.present?

        parts = []
        parts << "User:\n#{seed}" if seed.present?
        parts << "#{turn.role.capitalize}:\n#{text}" if text.present?
        parts.join("\n\n").presence
      end

      # The mainline oldest first, through the declared sources the composer
      # reads, stopping where it stops: a repaired round is the floor, or a
      # second compaction re-summarizes history the first already holds.
      def chain(node)
        mainline = []
        loop do
          segment = chain_segment(node)
          break if segment.empty?

          mainline = segment + mainline
          node = segment.first
          # SQL checkpoints nonempty JSON text, including blank Ruby
          # values; only arrived_summary may turn that checkpoint into a cut.
          break if node.compaction.to_h[AgentRunTasks::ModelTask::SUMMARY_SOURCE].nil? || repaired?(node)
        end
        mainline
      end

      # Follow only this reading chain, not every model row in the loop.
      # A marked round ends a segment: arrived_summary remains the one
      # authority for whether it really cuts history; a failed or empty
      # summary resumes the walk behind that round. The seed itself is
      # excluded, as its summary is the composition being repaired.
      # Each read position probes the existing unique (loop, key) index.
      # LATERAL LIMIT keeps that keyed probe inside each recursive step,
      # instead of building a loop-wide relation for every step.
      def chain_segment(node)
        binds = {
          node_id: node.id, loop_id: node.agent_run_id, model: AgentRunTasks::ModelTask.sti_name,
          summary: AgentRunTasks::ModelTask::SUMMARY_SOURCE,
        }
        AgentRunTasks::ModelTask.find_by_sql(AgentRunTask.sanitize_sql_array([<<~SQL.squish, binds]))
          WITH RECURSIVE history(id, input_from_node_keys, compaction, depth) AS (
            SELECT id, input_from_node_keys, compaction, 0
              FROM agent_run_tasks WHERE id = :node_id
            UNION ALL
            SELECT predecessor.id, predecessor.input_from_node_keys, predecessor.compaction, history.depth + 1
              FROM history
              CROSS JOIN LATERAL (
                SELECT source.*
                  FROM unnest(history.input_from_node_keys) WITH ORDINALITY AS reads(node_key, position)
                  CROSS JOIN LATERAL (
                    SELECT id, input_from_node_keys, compaction FROM agent_run_tasks
                     WHERE agent_run_id = :loop_id AND node_key = reads.node_key COLLATE "C" AND type = :model
                     LIMIT 1
                  ) source
                 ORDER BY reads.position LIMIT 1
              ) predecessor
             WHERE history.depth = 0 OR NULLIF(history.compaction ->> :summary, '') IS NULL
          )
          SELECT nodes.* FROM history
            CROSS JOIN LATERAL (SELECT * FROM agent_run_tasks WHERE id = history.id LIMIT 1) nodes
           WHERE history.depth > 0 ORDER BY history.depth DESC
        SQL
      end

      # Rendering needs model inputs and answers, never tool-result
      # bodies. Pictures need their ordered entries and blob metadata;
      # plain text uses the stored projection without loading fragments.
      def preload_rounds(rounds)
        ActiveRecord::Associations::Preloader.new(records: rounds, associations: [
          :output_body, { input_body: { content_uploads: { file_attachment: :blob } } },
        ]).call
        bodies = rounds.filter_map(&:output_body).select { |body| body.readable_text.nil? }
        bodies.concat(rounds.filter_map(&:input_body).select do |body|
          !body.readable_text.nil? && body.content_uploads.any?
        end)
        preload_entries(bodies)
      end

      def preload_entries(bodies)
        ActiveRecord::Associations::Preloader.new(
          records: bodies, associations: { content_body_entries: :content_fragment }
        ).call
      end

      # The one predicate every reader of the mark shares: only a summary
      # that ARRIVED cuts anything.
      def repaired?(node) = node.arrived_summary.present?

      # The composer's three segments, flattened. A repaired round leads
      # with its summary because that is what it read: everything before it
      # lives in that text and nowhere else. `fan` is the round's own tool
      # tasks by call id (`RoundReplay.fans_of`), the one fan both producers
      # read. `prompt` is the seed a conversation-backed round one opens
      # with; otherwise the `User:` is the round's AUTHORED prompt — an
      # assembled round's entries-shaped body has none and renders nothing
      # here (the request as JSON was never the summarizer's to read).
      # `steers` are the round's landed steers, each its own `User:`.
      # `bytes` is the fan's stored output sizes by row; a lone call
      # answers its own read.
      def render_round(source, fan, prompt: nil, steers: [], material: [], bytes: output_bytes(fan.values), receipts: {})
        parts = ["## Round #{source.node_key}"]
        carried = carried_summary(source)
        parts << "#{SUMMARY_LEAD}\n#{carried}" if carried.present?
        parts.concat(material)
        prompt ||= authored_prompt(source)
        parts << "User:\n#{prompt}" if prompt.present?
        steers.each { |steer| parts << "User:\n#{steer}" }
        answer = body_text(source, "output")
        parts << "Assistant:\n#{answer}" if answer.present?
        results = fan_results(fan, bytes, receipts: receipts)
        parts << results if results.present?
        parts.length > 1 ? parts.join("\n\n") : nil
      end

      # The same selected deliveries history and prune replay. Tool bodies
      # remain pointers even when an authored `results` slot selected them;
      # the person's answer and a model's words remain verbatim.
      def delivered_material(rounds, readers: AgentRuns::InputComposition.readers_by_round(rounds))
        deliveries = AgentRuns::InputComposition.delivered_sources_by_round(rounds, readers: readers)
        receipts = {}
        readers.each do |id, reader|
          if reader.compacted_source
            pending = reader.tool_receipts
            receipts[id] = pending.values.map { |item| "Tool #{item.payload.fetch("name")}: #{item.payload.fetch("output")}" }
            consumed = reader.paired_sources.reject { |tip| pending.key?(tip.tool_call_id) }
            deliveries[id] = consumed.map { |tip| [tip, false] } + deliveries.fetch(id)
          end
        end
        sources = deliveries.values.flatten(1).map(&:first).uniq(&:id)
        tools, words = sources.partition(&:tool_call?)
        AgentRuns::InputComposition.preload_material(words)
        bytes = output_bytes(tools)
        deliveries.to_h do |id, rows|
          rendered = rows.map do |tip, boundary|
            if tip.tool_call?
              pointer(tip, bytes.fetch(tip.id, 0))
            else
              "User:\n#{AgentRuns::TaskResultEnvelope.for(tip, boundary: boundary)}"
            end
          end
          [id, receipts.fetch(id, []) + rendered]
        end
      end

      # THE POINTER RULE: the tool, its status, the head of the call's
      # arguments and the size of what came back — in the older section
      # and the tail alike, since a summary is read INSTEAD of the history
      # and a tail body could only arrive as the summariser's paraphrase,
      # which is a wrong value, never a shorter one.
      def fan_results(fan, bytes, receipts: {})
        fan.values.sort_by(&:id).map do |tool|
          receipt = receipts[tool.tool_call_id]
          receipt ? "Tool #{tool.called_name}: #{receipt.payload.fetch("output")}" : pointer(tool, bytes.fetch(tool.id, 0))
        end.join("\n\n")
      end

      # THE OUTCOME BESIDE THE SIZE: `→ 0 bytes` alone read the same for a
      # call still on its runner, one that finished with nothing to say and
      # one that failed, and every real-model summary took it as "may not
      # have succeeded" — one re-ran the command. The status word stays the
      # row's own; the outcome says whether a result exists and, when it
      # does, whether the tool errored. Still no value rides. The call is
      # spelled as the delivered envelope's `<call>` line spells it
      # (`ToolTask#call_head`): the name the model called and the head of
      # its arguments. The size is the body's stored `byte_size` — the
      # row's fact, never a load. A call that settled without a result is
      # followed by the error envelope the model read for it (`RoundReplay::Pairing`), its
      # typed failure in the kernel's own words: the summary is read
      # INSTEAD of that envelope, so without it a call failed for its size
      # reads `{} → 0 bytes`, and the repaired round learns that something
      # failed but never why.
      def pointer(tool, bytes)
        count = ActiveSupport::NumberHelper.number_to_delimited(bytes)
        line = "Tool #{tool.called_name} (#{tool.status}, #{outcome_of(tool)}): #{tool.arguments_head} " \
          "→ #{count} bytes, not carried; re-read it if needed"
        return line if tool.status == "completed" || !tool.terminal?

        # A summary is read INSTEAD of the history, so a failed call keeps
        # the typed failure the model read. A failure the kernel wrote (a
        # bound crossed, an expiry, an approver's reason) has no result body,
        # and its detail is kernel text that rides along. A failure the
        # runner reported stored its words as the body, and its detail is
        # their first line: a value, which a pointer never carries.
        detail = tool.output_body.nil?
        "#{line}\n#{AgentRuns::RoundReplay::Pairing.failure_output(tool, detail: detail)}"
      end

      # A completed row carries its envelope's `is_error` (data, never
      # control — `RoundReplay::Pairing`); any other terminal row settled
      # without a result; a live one has none YET.
      def outcome_of(tool)
        if tool.status == "completed"
          tool.output_summary["is_error"] ? "error" : "ok"
        elsif tool.terminal?
          "no result"
        else
          "no result yet"
        end
      end

      def carried_summary(node)
        summary = node.arrived_summary
        summary && body_text(summary, "output")
      end

      def body_text(node, role)
        node.public_send(:"#{role}_body")&.effective_text.to_s
      end

      # The round's AUTHORED words, then its pictures as pointers; an
      # assembled round's entries-shaped body has no words and renders
      # nothing here, its pictures included (they are the seed's).
      def authored_prompt(node)
        body = node.input_body
        words = body&.readable_text
        words.nil? ? nil : with_pointers(words, body)
      end

      # Clamped to a tool_input's room, an eighth of a prompt's; the tail
      # goes last because it is the part the summarizer keeps specific.
      #
      # THE WALL MEASURES THE ENCODED ENVELOPE, SO THE CLAMP MUST TOO. The
      # bound is `bounded_json`'s: `CanonicalJson.bytesize`, which is what
      # `JSON.generate` writes. Escaping expands a transcript by its own
      # newlines, quotes and backslashes — under 2% on prose, over 6% on
      # the tool pointers a coding round writes, since `pointer` embeds a
      # call's arguments as JSON INSIDE a string and every quote doubles.
      # A fixed headroom cannot cover a content-dependent expansion, so
      # the room is re-measured: clamp, encode, and clamp AGAIN from the
      # originals at the measured ratio, with the envelope's own bytes
      # held out of it. Same shape as the summarizer's window fit.
      # Over the limit the measured ratio is below one, so each pass
      # shrinks the room in proportion to the overrun it measured; the
      # one-byte step beside it only guarantees the loop ends. A larger
      # fixed step would throw away room the measurement found, and could
      # cut a tail that fits whole.
      def clamp_pair(older, tail, bound, envelope = {})
        limit = Nexus::SizeBounds::BOUNDS.fetch(bound).fetch(:value)
        fixed = encoded_size(envelope, "", "")
        room = limit - Summarizer::DELEGATED_HEADROOM
        pair = ["", ""]
        while room.positive?
          kept_tail = clamp_to(tail, room)
          pair = [clamp_to(older, room - kept_tail.bytesize), kept_tail]
          encoded = encoded_size(envelope, *pair)
          return pair if encoded <= limit

          raw = pair.sum(&:bytesize)
          break if raw.zero? || encoded <= fixed

          room = [((limit - fixed) * raw / (encoded - fixed).to_f).floor, room - 1].min
        end
        pair
      end

      def encoded_size(envelope, older, tail)
        Nexus::SizeBounds.json_bytesize(envelope.merge("history" => older, "retained_tail" => tail))
      end

      def clamp_to(text, room) = Nexus::Elision.clamp(text, room)
    end
  end
end
