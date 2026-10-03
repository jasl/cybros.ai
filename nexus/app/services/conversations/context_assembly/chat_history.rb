module Conversations
  class ContextAssembly
    # Callers state intent (at most so many entries or tokens); the block
    # owns the mechanics — newest-first selection, chronological render, and
    # the evidence of what was left out. Positions never cross outward. A
    # turn renders by its KIND: a summary as its content under the header, a
    # loop-backed reply as its rounds from rows, every other turn as its
    # content — and a reply turn opens with its PREFACE (what its request
    # laid between history and its input) then its SEED, the words that
    # asked for it, unless an in-turn summary leads it. A SIDE conversation's
    # inherited turns close with one boundary item, the kernel's fact that
    # they are reference. In a GROUP a reply turn ANOTHER agent answered is
    # not the assembling model's own work: it renders as one user-side
    # segment — its seed under the seed's own voice, then its final text in
    # the speaker envelope — never as that agent's rounds or its preface.
    class ChatHistory
      # `compacted_count` is what a summary stands in for, distinct from
      # `skipped_count`: conflating them would report a compaction as a loss.
      # `carried_lead` is the lead run of the NEWEST in-window preface of the
      # answerer's own reply turn that carries one, as `[role, text]` pairs —
      # `[]` when the window holds no such preface — so a turn whose lead
      # equals it lays none (ContextAssembly.assemble).
      Selection = Data.define(:segments, :selected_count, :skipped_count,
        :skipped_reason, :compacted_count, :carried_lead) do
        def initialize(compacted_count: 0, carried_lead: [], **) = super
      end

      ReplayWindow = Data.define(:rounds, :summary, :cleared)

      # At most this many newest turns fetch their bodies per assembly; an
      # explicit larger `max_entries` widens the window to match.
      CANDIDATE_LIMIT = PromptTemplate::MAX_ENTRIES

      COMPACTION_KIND = "compaction_summary".freeze
      # Framed here, not stored framed: the row stays clean for a client,
      # and the frame belongs beside the cut it explains. The re-read rule
      # is the kernel's sentence, never the summariser's.
      COMPACTION_HEADER = <<~TEXT.strip.freeze
        The earlier part of this conversation was summarized to fit the
        context window. #{Compaction::REREAD_RULE}
        Here is that summary:
      TEXT
      # The in-turn summary a repaired round read rides as the round read
      # it: the user's material, bare.
      IN_TURN_SUMMARY_ROLE = "user".freeze
      # A reply turn's own prompt renders in the role it rode the wire in
      # (`Inline.call(role: "user", …)`) behind the preface it rode behind, so
      # the next turn's prefix is the earlier request whole, its per-turn text
      # and trailing user message included — for the answerer's own turns.
      # What still edits it is written where it happens: a block ahead of
      # history that changes when written (memory, a slot, a `{{date}}`), a
      # stated history bound trimming the oldest turns, a compaction.
      SEED_ROLE = "user".freeze
      # THE BOUNDARY ITEM: after the last inherited turn a side renders,
      # one kernel fact — no instruction, no product name; the agent's own
      # words about the side ride its inline tail. USER role, not system:
      # the Anthropic protocol hoists every system-role entry into the top
      # system block, which would move the parent's prefix bytes at byte
      # one and break the pinned cache property; in the user role it
      # merges with the side's next user text and the prefix above it is
      # the parent's, untouched.
      BOUNDARY_ROLE = "user".freeze
      BOUNDARY_TEXT = "[The turns above are inherited from the parent conversation as reference. " \
        "Only the turns after this point belong to this conversation.]".freeze
      # ANOTHER AGENT'S REPLY: what it said, read as a message from it —
      # the user side of the assembling model's wire.
      PEER_REPLY_ROLE = "user".freeze

      class << self
        # The compaction cursor, derived from the timeline and public so
        # the repair reads the same cut: a stored column would desync on
        # fork and on the regenerate corridor's window. One indexed query.
        def compaction_cut(conversation, before_position: nil)
          conversation.timeline.compaction_position(
            surface: :assembly, before_position: before_position, kind: COMPACTION_KIND
          )
        end

        # Only a settled summary cuts: a running or failed one would
        # replace the whole conversation with an empty turn.
        def compaction_summary?(turn)
          turn.kind == COMPACTION_KIND && turn.completed?
        end

        # History is optional: the current question is funded separately by
        # assembly, including when regenerating an earlier turn. The traces
        # load whatever the replay mode: a round's order and a reply's label
        # are the turn's own facts, not replay material. `answerer` is the User whose
        # turn this history is assembled for (the addressee of the input, the
        # regenerated turn's own): a reply turn answered by another agent
        # renders as that agent's message to it; nil renders every reply as the
        # model's own — the estimate's and the summarizer's read, and every 1:1
        # lane's bytes. `carries` is the placement predicate (AttachmentLine): a
        # seed's or a message turn's picture rides native or as the index line
        # by it; nil keeps every part. `conversation` is the Conversation or a
        # `Source`: a standalone loop's has no timeline, and its history is
        # empty — no read, no evidence of a skip. `replay` is the turn's
        # replay ask: every eligible candidate is decided once and carries its
        # reasoning into the fit (Replayed) — history and the traces it holds
        # share one budget, in tokens and in the `byte_budget` the request's
        # seal leaves history, and the walk stops at whichever crosses first.
        def call(conversation:, before_position: nil, max_entries: nil,
                 token_budget: nil, profile: nil, answerer: nil, carries: nil,
                 replay: nil, byte_budget: nil)
          if token_budget && profile.nil?
            raise ArgumentError, "a token budget needs the profile that counts it"
          end
          source = Source.of(conversation)
          return Selection.new(segments: [], selected_count: 0, skipped_count: 0, skipped_reason: nil) if source.standalone?

          candidates, beyond_window, compacted, carriers = candidate_segments(
            source.conversation, before_position, max_entries, answerer, carries, replay
          )
          candidates = replayed(candidates, replay, profile) if replay&.replay?
          select_newest_first(candidates, beyond_window,
            max_entries: max_entries, token_budget: token_budget, byte_budget: byte_budget,
            profile: profile, compacted: compacted, carriers: carriers)
        end

        private

          def replayed(candidates, replay, profile)
            landed, reasons = Replayed.decide(candidates, replay: replay, profile: profile)
            if reasons.any?
              Rails.logger.info(
                "event=reasoning_replay mode=#{replay.mode} " \
                "target=#{replay.target.provider_id}/#{replay.target.model_id} " \
                "replayed=#{landed.count(&:reasoning?)} degradations=#{reasons.join(",")}"
              )
            end
            landed
          end

          # One batched body read inside the candidate window; older turns
          # come back as a count so the evidence still tells the truth. The
          # CARRIERS are where each own reply turn's rendered preface with a
          # lead begins in the flat list, beside that lead's `[role, text]`.
          def candidate_segments(conversation, before_position, max_entries, answerer, carries, replay)
            # Bounded both ways in SQL, so a compacted conversation never
            # touches the turns its summary replaced.
            timeline = conversation.timeline
            cut = compaction_cut(conversation, before_position: before_position)
            limit = (max_entries || 0).clamp(CANDIDATE_LIMIT..)
            window = timeline.entries(
              surface: :assembly, before_position: before_position,
              from_position: cut, limit: limit, newest: true
            ).map(&:turn)
            compacted = cut ? timeline.content_bearing_count(
              surface: :assembly, before_position: cut
            ) : 0
            # Ancestor retention can commit while a fork prepares its own
            # request. Materialize first, then verify the finite selected set:
            # every retry excludes at least one irreversibly pruned loop, and
            # the timeline window remains fixed throughout this read.
            expired = []
            loop do
              segments, carriers, loop_ids = render_candidate_window(conversation, window, answerer, carries,
                excluded_loop_ids: expired, replay: replay)
              changed = ApplicationRecord.uncached do
                AgentLoop.where(id: loop_ids).where.not(details_pruned_at: nil).pluck(:id)
              end
              if changed.empty?
                return [segments, beyond_window_count(timeline, window, cut, before_position), compacted, carriers]
              end
              expired.concat(changed)
            end
          end

          def render_candidate_window(conversation, window, answerer, carries, excluded_loop_ids:, replay:)
            variant_ids = window.filter_map(&:active_variant_id)
            loop_variant_ids = window.reject { |turn| turn.kind == COMPACTION_KIND || peer_reply?(turn, answerer) }
              .filter_map(&:active_variant_id)
            loops = AgentLoop.where(conversation_turn_variant_id: loop_variant_ids, details_pruned_at: nil)
              .where.not(id: excluded_loop_ids)
              .index_by(&:conversation_turn_variant_id)
            # Own loop replies replay their rounds. Their final content is
            # only a display projection; peers, summaries and manual variants
            # still read their adopted content below.
            bodies = ContentBody.preload_for_render(
              ContentBody.where(conversation_turn_variant_id: variant_ids, role: ["prompt", Preface::ROLE])
                .or(ContentBody.where(conversation_turn_variant_id: variant_ids - loops.keys, role: "content"))
            )
              .group_by(&:role)
              .transform_values { |rows| rows.index_by(&:conversation_turn_variant_id) }
            contents = bodies.fetch("content", {})
            prompts = bodies.fetch("prompt", {})
            prefaces = bodies.fetch(Preface::ROLE, {})
            retained = RetainedSteers.messages_by_variant(variant_ids - loops.keys)
            replay_windows = spine_rounds(loops.values).transform_values { |rows| replay_window(rows) }
            rounds = replay_windows.values.flat_map(&:rounds)
            fans = AgentLoops::RoundReplay.fans_of(rounds)
            result_round_ids = replay_windows.values.flat_map { |part| part.rounds.drop(part.cleared).map(&:id) }
            AgentLoops::RoundReplay.preload(rounds, calls: fans.slice(*result_round_ids).values.flat_map(&:values))
            # ONE walk per assembly over every `task` call in the window: a
            # later turn pairs a blocking call with its branch's last word,
            # as the continuation's own request did.
            tips = AgentLoops::BranchClosure.tips_by_call_key(fans.values.flat_map(&:values))
            boundary_after = side_boundary_after(conversation, window)
            steers = AgentLoops::Steers::Landed.texts_by_round(rounds)
            readers = AgentLoops::InputComposition.readers_by_round(rounds)
            material = AgentLoops::InputComposition.material_by_round(rounds, readers: readers)
            pair_sources = if AgentLoops::RoundReplay.native_replay?(replay)
              readers.select { |_, reader| reader.compacted_fan.any? }.transform_values(&:compacted_source)
            else
              {}
            end
            variant_traces, round_traces = traces(variant_ids, rounds + pair_sources.values)
            pair_traces = pair_sources.transform_values { |source| round_traces[source.selected_model_invocation_id] }
            paired = AgentLoops::InputComposition.compacted_pairs_by_round(readers, traces: pair_traces,
              cleared_ids: rounds.map(&:id) - result_round_ids)
            preload_voices(window)
            carriers = []
            segments = window.each_with_object([]) do |turn, flat|
              variant_id = turn.active_variant_id
              opening = nil
              # A summary renders its adopted content whatever engine wrote
              # it; another agent's reply renders its adopted content in
              # the envelope; the assembling answerer's own loop-backed
              # reply renders its rounds and its content is the presenter's
              # projection, never read here.
              rendered = if turn.kind == COMPACTION_KIND
                content_segments(turn, contents[variant_id], variant_traces[variant_id], carries,
                  opening: [seed_segment(turn, prompts[variant_id], carries)].compact)
              elsif peer_reply?(turn, answerer)
                peer_reply_segments(turn, contents[variant_id], answerer,
                  seed: seed_segment(turn, prompts[variant_id], carries),
                  steers: retained_steer_segments(retained.fetch(variant_id, [])))
              else
                opening = opening_segments(turn, prefaces[variant_id], prompts[variant_id], carries)
                if loops[variant_id].nil?
                  follow_ups = retained_steer_segments(retained.fetch(variant_id, []))
                  content_segments(turn, contents[variant_id], variant_traces[variant_id], carries,
                    opening: opening + follow_ups)
                else
                  round_segments(turn, replay_windows.fetch(loops[variant_id].id) { replay_window([]) }, fans, tips,
                    round_traces, steers, material, paired, pair_traces, opening: opening)
                end
              end
              lead = Preface.lead_pairs(prefaces[variant_id])
              # Only an opening that RENDERED carries its lead: an in-turn
              # summary stands in for the preface it replaced.
              carriers << [flat.length, lead] if lead.any? && opening&.first&.equal?(rendered.first)
              rendered << Segment.plain(BOUNDARY_ROLE, BOUNDARY_TEXT) if turn.equal?(boundary_after)
              flat.concat(rendered)
            end
            [segments, carriers, loops.values.map(&:id)]
          end

          # The inherited turn the boundary follows: the newest window turn
          # at or under the parent's bound (the depth-1 edge; deeper
          # ancestors are capped under it). Nil off a side, and nil when no
          # inherited turn is in the window — a compaction cut past the
          # boundary or an empty inheritance renders no boundary. A plain
          # candidate segment: priced by FillCost, and newer than every
          # inherited turn, so newest-first selection drops it last of them.
          def side_boundary_after(conversation, window)
            return nil unless conversation.side?

            bound = conversation.conversation_ancestries.find_by(depth: 1)&.boundary_position
            window.reverse.find { |turn| turn.position <= bound } if bound
          end

          # THE OPENING of the answerer's own reply turn: its preface — what
          # its request laid between history and its input, sealed as sent
          # (Preface) — then its seed, in the order the request carried them.
          # A peer's reply never opens with its preface: another agent's
          # per-turn text is its own context, never this one's.
          def opening_segments(turn, preface, prompt, carries)
            Preface.segments(preface) + [seed_segment(turn, prompt, carries)].compact
          end

          # THE SEED: the words that opened a reply turn, a plain user-role
          # segment ahead of the turn's own material — rendered whatever the
          # turn's status (a failed reply still carries the question),
          # priced and dropped like any segment (older than the turn's
          # rounds, so it drops first), and passed over by the replay ladder
          # by its role and its nil trace. Nil when the body is absent or
          # carries no readable text (a raw input's entries — raw is never
          # enriched, so its pictures do not render alone). Rendered through
          # the speaker envelope by the TURN (its author, origin and sender
          # stamp), so a peer's row reads here exactly as it read on the
          # wire; the pictures follow the words, the person's message shape
          # the door wrote — a picture with no words is a seed of its own.
          def seed_segment(turn, body, carries)
            words = body&.readable_text
            return nil if words.nil?

            text = SpeakerEnvelope.for_turn(turn, words)
            parts = Segment.text_parts(text.presence) +
              AttachmentLine.parts(body.upload_parts, carries: carries)
            Segment.plain(SEED_ROLE, nil, parts: parts) unless parts.empty?
          end

          # RULE 3: a reply turn answered by an agent other than the one
          # this history is assembled for.
          def peer_reply?(turn, answerer)
            answerer && turn.kind == "direct_reply" && turn.role == "assistant" &&
              turn.answering_user_id != answerer.id
          end

          # Another agent's reply as ONE user-side segment of its FINAL
          # TEXT — the variant's adopted `content`, the same body the
          # presenter shows — in the speaker envelope of its answerer,
          # preceded by its seed under the seed's own voice (the question
          # it answered). Never its rounds: its calls and results are its
          # working, and a wire pairs calls with results of ONE loop. The
          # seed is skipped when the assembling answerer spoke it (its own
          # `send` is already the call in its own rounds — a user-role
          # message claiming to be the model is bench-sensitive) and when
          # it was the kernel's receipt (that mail was the other agent's).
          # A turn that produced no text renders only its seed.
          def peer_reply_segments(turn, body, answerer, seed: nil, steers: [])
            seed = nil if ConversationInput::KERNEL_ORIGINS.include?(turn.origin) ||
              (turn.speaker_actor.kind == "member" && turn.speaker_actor.user_id == answerer.id)
            text = body&.effective_text
            return [seed].compact + steers if text.blank?

            [seed].compact + steers +
              [Segment.plain(PEER_REPLY_ROLE, SpeakerEnvelope.render(author: turn.answering_user, text: text))]
          end

          def retained_steer_segments(messages)
            messages.map do |message|
              Segment.plain(message.role, nil, parts: message.parts, alone: true)
            end
          end

          # A message turn's content carries its pictures like a seed
          # (the adopted input body, joins and all); a summary's and an
          # assistant's never do. A reply's folded text is labelled by its
          # trace's last message's phase: the fold ends with the final words.
          # `opening` is what leads it: a reply's preface and seed.
          def content_segments(turn, body, trace, carries, opening: [])
            text = body&.effective_text
            attachments = body ? body.upload_parts : []
            return opening if text.blank? && attachments.empty?

            text = if compaction_summary?(turn)
              "#{COMPACTION_HEADER}\n\n#{text}"
            elsif turn.role == "user"
              SpeakerEnvelope.for_turn(turn, text)
            else
              text
            end
            parts = Segment.text_parts(text.presence) + AttachmentLine.parts(attachments, carries: carries)
            opening + [Segment.plain(turn.role, nil, parts: parts, trace: trace, phase: trace&.assistant_phase)]
          end

          # The envelope's decision reads each turn's speaker, its own
          # conversation (an inherited turn is judged where it was spoken,
          # so a side's prefix stays the parent's bytes) and its own
          # answerer with that answerer's Human: one preload for the
          # window, no query per turn.
          def preload_voices(window)
            ActiveRecord::Associations::Preloader.new(
              records: window,
              associations: [{ speaker_actor: :user }, :conversation, { answering_user: :steward }]
            ).call
          end

          # The spine in chain order — one continuation per round, appended
          # as the loop grew, so row order IS the chain.
          def spine_rounds(loops)
            return {} if loops.empty?

            AgentLoopNodes::ModelTask
              .where(agent_loop_id: loops.map(&:id), continuation_source: AgentLoops::Tasks::Compile::ROUND)
              .order(:id)
              .group_by(&:agent_loop_id)
          end

          # The in-turn summary cuts: the newest round whose summary ARRIVED
          # leads with that summary and the rounds it replaced leave history
          # — the chain break the continuation honours, on this side; the
          # seed goes with them (the summary stands in for everything the
          # repaired round read, and the summarizer saw the seed as its
          # round-one `User:`) and so does the preface before it, else the
          # opening leads. The prune mark clears too: the rounds chain-before
          # the newest `pruned_before` render their results as the
          # placeholder, so history shows what the model
          # read after the prune and the next turn's prefix stays byte-stable
          # against the pruned round's own request. The material and the
          # steers a round read lead that round, each its own user message
          # in the bytes the wire carried — before the round's answer, as its
          # sealed request had them, never merged with a neighbour
          # (`Segment#alone`).
          def replay_window(rounds)
            rounds.each_with_index.reverse_each do |round, index|
              summary = round.arrived_summary
              if summary
                kept = rounds.drop(index)
                return ReplayWindow.new(rounds: kept, summary: summary, cleared: Compaction::Prune.cleared_count(kept))
              end
            end
            ReplayWindow.new(rounds: rounds, summary: nil, cleared: Compaction::Prune.cleared_count(rounds))
          end

          def round_segments(turn, window, fans, tips, traces, steers, material, paired, pair_traces, opening: [])
            lead = window.summary ? [in_turn_summary(window.summary)] : opening
            lead + window.rounds.each_with_index.flat_map do |round, index|
              Array(compacted_pair_segment(paired[round.id], pair_traces[round.id])) + material.fetch(round.id, []).map do |message|
                Segment.plain(message.role, nil, parts: message.parts, alone: true)
              end +
                steers.fetch(round.id, []).map { |text| Segment.plain(SEED_ROLE, text, alone: true) } +
                Array(round_segment(turn, round, fans.fetch(round.id, {}), tips,
                  traces[round.selected_model_invocation_id], cleared: index < window.cleared))
            end
          end

          def compacted_pair_segment(paired, trace)
            return nil unless paired

            Segment.round("assistant", nil, calls: paired.call_items,
              trailing: paired.trailing, first_slot: paired.first_slot, results: paired.result_items, trace: trace)
          end

          def in_turn_summary(summary)
            body = summary.content_bodies.find_by(role: "output")
            # A retention commit may remove this body after the snapshot read
            # chose its summary. The final loop-marker check retries the whole
            # window; this temporary empty segment is never sent to a model.
            if body.nil? && AgentLoop.where(id: summary.agent_loop_id).where.not(details_pruned_at: nil).exists?
              return Segment.plain(IN_TURN_SUMMARY_ROLE, nil)
            end

            Segment.plain(IN_TURN_SUMMARY_ROLE, "#{Compaction::REREAD_RULE}\n\n#{body.effective_text}")
          end

          # Rendered whatever the turn's status: a held or canceled turn's
          # dangling call closes with the pairing envelope, and a round that
          # neither spoke nor called adds nothing. The segment carries the
          # round as RoundReplay PLACED it — its calls and labelled messages
          # at their ordinals — so the replay ladder lands into that order
          # and never makes a second one. A round with no host words (a
          # labelled round's ride `trailing`, or it said none) gets no text
          # part: a fence the ladder lands then stands alone, as the loop
          # lane's host sends it, never beside an empty part it would join.
          def round_segment(turn, round, fan, tips, trace, cleared: false)
            rendered = AgentLoops::RoundReplay.call(round, fan_by_call_id: fan, tips_by_call_key: tips,
              cleared: cleared)
            return nil if rendered.empty?

            Segment.round(turn.role, rendered.text, calls: rendered.call_items, trailing: rendered.trailing,
              first_slot: rendered.first_slot, results: rendered.result_items, trace: trace)
          end

          # The provenance sidecars, batched like the content read: one
          # envelope per variant and one per round's invocation, wrapped for the ladder.
          def traces(variant_ids, rounds)
            [
              trace_envelopes(
                ContentBody.where(conversation_turn_variant_id: variant_ids),
                :conversation_turn_variant_id
              ),
              trace_envelopes(
                ContentBody.where(model_invocation_id: rounds.filter_map(&:selected_model_invocation_id)),
                :model_invocation_id
              ),
            ]
          end

          def trace_envelopes(bodies, key)
            bodies.where(role: "reasoning_trace")
              .includes(content_body_entries: :content_fragment)
              .index_by(&key)
              .transform_values do |body|
                envelope = body.content_body_entries.first&.content_fragment&.payload
                ModelReasoning::Trace.new(envelope: envelope) if envelope
              end.compact
          end

          # Counts context, not rows: a contentless turn is not lost
          # history. One COUNT over the range the window did not reach.
          def beyond_window_count(timeline, window, cut, before_position)
            oldest = window.first&.position
            # An empty window means the LIMIT reached nothing, so there is
            # nothing beyond it either.
            return 0 if oldest.nil?

            timeline.content_bearing_count(
              surface: :assembly, from_position: cut, before_position: oldest
            )
          end

          # Newest first, stop at the first bound crossed, then reverse
          # because the model reads time forward; the nearest bound that
          # fired names the reason, the window only when nothing tighter did.
          # Tokens and bytes are one fit: whichever crosses first is
          # `budget_exceeded`.
          def select_newest_first(candidates, beyond_window,
                                  max_entries:, token_budget:, byte_budget:, profile:,
                                  compacted: 0, carriers: [])
            unbounded = max_entries.nil? && token_budget.nil? && byte_budget.nil?
            if unbounded
              return Selection.new(
                segments: candidates, selected_count: candidates.length,
                skipped_count: beyond_window,
                skipped_reason: beyond_window.positive? ? "candidate_limit" : nil,
                compacted_count: compacted, carried_lead: carried_lead(carriers, 0)
              )
            end

            selected = []
            used_tokens = 0
            used_bytes = 0
            skipped_reason = nil
            candidates.reverse_each do |segment|
              if max_entries && selected.length >= max_entries
                skipped_reason = "entry_limit"
                break
              end
              tokens = token_budget ? FillCost.segment(segment, profile) : 0
              bytes = byte_budget ? segment.bytes : 0
              if (token_budget && used_tokens + tokens > token_budget) ||
                  (byte_budget && used_bytes + bytes > byte_budget)
                skipped_reason = "budget_exceeded"
                break
              end
              used_tokens += tokens
              used_bytes += bytes
              selected << segment
            end

            skipped = (candidates.length - selected.length) + beyond_window
            skipped_reason = "candidate_limit" if skipped_reason.nil? && beyond_window.positive?
            Selection.new(
              segments: selected.reverse,
              selected_count: selected.length,
              skipped_count: skipped,
              skipped_reason: skipped_reason,
              compacted_count: compacted,
              carried_lead: carried_lead(carriers, candidates.length - selected.length)
            )
          end

          # The newest carrier whose preface starts inside the selected run.
          def carried_lead(carriers, first_selected)
            carriers.select { |index, _lead| index >= first_selected }.max_by(&:first)&.last || []
          end
      end
    end
  end
end
