module Conversations
  # The kernel compiles the prompt from what it holds, one block class per
  # source; callers state intent (how much history), the blocks own the
  # mechanics, and the facade owns the one wire rule: same-role segments merge.
  class ContextAssembly
    # `uploads` is THE PLACED SET: the distinct `ContentUpload` rows
    # the materialized messages place natively, first-occurrence order —
    # what acceptance judges and the request seal binds, so `Build` finds
    # exactly what it will send at `source.content_uploads`. Collected
    # from the segments' own rows, never a fresh account-wide lookup.
    #
    # `blocks` is the template's evidence: one row per block in
    # the template's order — what it cost, what the allocator gave it, and
    # its state. Evidence, never a byte change: a floor the window cannot
    # fund is `floor_unmet` on bytes that still send whole; the window gate
    # alone refuses. Not persisted.
    #
    # `preface` is THE TURN'S PREFACE: the segments laid between history and
    # the input, as rendered, each beside the template block it came from
    # (`Preface::Laid`) — what a reply turn seals (Preface.seal) so later
    # history replays it in place. A lead the window already carried is not
    # laid: it rides as CARRIED, the lead the turn relied on.
    Assembled = Data.define(:messages, :history, :memory, :skills, :slots, :uploads, :blocks, :preface) do
      def message_count = messages.length

      # A memory-free (or slot-free, or skill-free) assembly still answers
      # a block, so every reader can ask the same question without a nil check.
      def initialize(memory: MemoryBlock::Block.empty, skills: SkillsBlock::Block.empty,
                     slots: SlotBlocks::Blocks.none, uploads: [], blocks: [], preface: [], **)
        super
      end
    end

    # One block's evidence: `state` ∈ selected | empty | floor_unmet | carried;
    # `tokens` its fill cost; `allocated_tokens` the allocator's grant —
    # nil when no window sized anything (the unbounded arm).
    BlockEvidence = Data.define(:key, :index, :type, :role, :state, :tokens, :allocated_tokens)
    # The lead block's state when the window already carried it.
    CARRIED = "carried".freeze

    # The allocator's answer for one assembly: history's token budget
    # (nil = unbounded), the allocations by block key (empty when no
    # window ran the allocator) and each floor's cost.
    Sized = Data.define(:history_budget, :allocations, :costs)

    # The replay ask: mode (none | last_turn | all) plus the resolved
    # target the ladder gates against.
    #
    # THE DEFAULT IS `all`, the same on every row: the kernel replays every
    # earlier round's reasoning the target can read exactly as the request
    # that first carried it did, so a later request extends the previous
    # one. A caller may still name `none | last_turn | all` for one turn;
    # the next turn at the default carries what it left out again.
    Replay = Data.define(:mode, :target) do
      class << self
        # The one construction every send-side caller shares: the resolved
        # selection IS the target. A nil mode is the kernel's default.
        def from_selection(selection, mode: nil)
          new(
            mode: (mode || self::DEFAULT_MODE).to_s,
            target: ModelReasoning::ReplayLadder::Target.new(
              provider_id: selection.provider_id,
              model_id: selection.execution_profile.model_pin,
              reasoning_enabled: selection.reasoning.enabled,
              capability: selection.capabilities.reasoning_replay,
              allow_empty_thinking_signature: selection.execution_profile.wire_option(:allow_empty_thinking_signature) == true
            )
          )
        end
      end

      def replay? = %w[last_turn all].include?(mode)
    end
    Replay::DEFAULT_MODE = "all".freeze

    class << self
      # Messages plus each block's selection evidence, for a trim-planning client.
      # `inline` is the client's own text and never yields; only history does.
      # `principal` is the User whose turn this assembles — the poster, the
      # regenerating caller, the estimating caller — because the memory block's
      # `user/` rung is that User's controlling Human's, never the conversation's
      # creator's; its `persona` slot is that Human's too. `declaring_profile` is the
      # Agent the turn runs under (ConversationInput#declaring_profile), whose
      # `system_prompt` slot leads — nil for a turn no profile declares. `answerer` is
      # the User the turn answers as: history renders another agent's reply as a
      # message to it; nil renders every reply as the model's own (the estimate's
      # read). `attachments` are the input body's bound rows in part order, and
      # `carries` the one placement predicate the caller built from ITS selection
      # (`AttachmentLine.carries_for`) — `assemble` never holds the selection; nil
      # keeps every part native. `template` is the block ORDER: the addressee
      # profile's own under `assembly`, else `PromptTemplate::DEFAULT` — the same
      # blocks, the same merge, the same bytes under `default` as before the template
      # existed; `variables` the turn's values for its declared names. `source` is the
      # blocks' `Source` when there is no conversation — a standalone loop's seed: its
      # room, no timeline; `conversation` is that source for every turn. `tools` is
      # THE TOOL SET THE TURN WILL DECLARE — the caller's own fact: the skills block
      # renders only when it names `nexus.skill.load`, so a turn without the tool has
      # no catalog and costs no query. Explicit Runner routes select their catalogs.
      # `preface` is a turn's SEALED preface re-asked (regenerate, `Preface.laid`): laid verbatim
      # between history and the input in place of what the template would render
      # there — the question is the turn's, the per-turn text it carried included, and a lead
      # it relied on the window for laid when this window no longer carries it (funded either way).
      def assemble(conversation: nil, principal:, prompt: nil, before_position: nil,
                   history_max_entries: nil, history_token_budget: nil,
                   profile: nil, limits: nil,
                   reasoning: nil, inline: nil, declaring_profile: nil, answerer: nil,
                   attachments: [], carries: nil, template: nil, variables: nil, source: nil,
                   tools: nil, environment: nil, preface: nil,
                   memory_context: source&.conversation&.memory_context || conversation&.memory_context)
        source = Source.of(source || conversation)
        template ||= PromptTemplate::DEFAULT
        overrides, lead, tail = inline_segments(inline)
        lead = EnvironmentLead.call(environment) + lead
        input = Inline.call(role: "user", text: prompt, attachments: attachments, carries: carries)
        sources = MacroSources.call(conversation: source, principal: principal,
          declaring_profile: declaring_profile, variables: template.values(variables))
        slots = SlotBlocks.call(conversation: source, principal: principal,
          declaring_profile: declaring_profile, overrides: overrides, sources: sources,
          slots: template.slot_names)
        memory = template.memory? ? MemoryBlock.call(conversation: source, principal: principal, memory_context: memory_context) : MemoryBlock::Block.empty
        skills = if template.skills?
          SkillsBlock.call(conversation: source, principal: principal, tools: tools,
            declaring_profile: declaring_profile, environment: environment)
        else
          SkillsBlock::Block.empty
        end
        named = named_blocks(template, slots, memory, skills, lead, tail, input, sources)
        leading, trailing = template.split_at_history
        # A sealed preface stands in for the whole post-history run: those
        # blocks render nothing and the preface is funded as one floor.
        named = named.merge(trailing.index_with { [] }) if preface
        floor_keys = template.keys.without("history")
        floors = floor_keys.to_h { |key| [key, cost(named.fetch(key), profile)] }
        floors[PREFACE_FLOOR] = cost(preface.map(&:segment), profile) if preface
        floor_bytes = (floor_keys.flat_map { |key| named.fetch(key) } + Array(preface).map(&:segment)).sum(&:bytes)
        # Every named block is a REQUIRED floor and history the one optional
        # child: the slots, memory and the text are funded before history,
        # which trims first — charging them afterwards would push an assembly
        # past the window it was fitted to.
        sized = size(
          floors: floors,
          history: template.history&.budget || {}, explicit: history_token_budget,
          profile: profile, limits: limits
        )
        # History and the reasoning it carries share ONE fit, in the window's
        # tokens and in the bytes the request's seal leaves them.
        history = ChatHistory.call(
          conversation: source,
          before_position: before_position,
          max_entries: history_max_entries || template.history&.max_entries,
          token_budget: sized.history_budget,
          byte_budget: (SEAL_BYTES - floor_bytes).clamp(0..),
          profile: profile,
          answerer: answerer,
          carries: carries,
          replay: reasoning
        )
        # THE ORDER IS THE TEMPLATE'S; the default's is the cache's — the slots lead
        # (identity, the room, the person), then memory and the skills catalog: all change
        # only when written, history every reply, so the front of the prefix stays warm
        # and the stable marker (Nexus::PromptCache::Breakpoints) lands after them; the
        # per-turn text rides behind history as the turn's PREFACE, which the next turn's
        # history replays where this request placed it:
        # [system_prompt][character][persona][memory][skills][history][lead][tail][input].
        placed = named.merge("history" => history.segments)
        carried = preface.nil? && carried_lead?(lead, history)
        laid = preface ? re_laid(preface, history) : trailing.flat_map do |key|
          placed.fetch(key).map do |segment|
            Preface::Laid.new(block: key, segment: segment, carried: carried && key == Preface::LEAD)
          end
        end
        segments = leading.flat_map { |key| placed.fetch(key) } + laid.reject(&:carried).map(&:segment) +
          placed.fetch("input")
        merged = merge_adjacent_roles(segments)
        Assembled.new(messages: materialize(merged), uploads: placed_uploads(merged),
          history: history, memory: memory, skills: skills, slots: slots,
          blocks: evidence(template, placed, sized, history, profile, carried: carried), preface: laid)
      end

      private

        # THE ANSWER ROOM: on a hard or shared window the turn's own answer
        # needs room the request must leave it — `min(32k, 12.5 %)` of the
        # window, the room a coding agent keeps for its answer, the fraction
        # the floor a small window needs. A row that plans to an advisory
        # bound below its hard window already has that room.
        ANSWER_ROOM_TOKENS = 32_768
        ANSWER_ROOM_FRACTION = 0.125
        # The request's seal refuses what it cannot store: history's bytes
        # are fitted to what the floors leave of it, as its tokens are.
        SEAL_BYTES = Nexus::SizeBounds.fetch(:snapshot_bound)
        # With ONE optional child no strategy is distinguishable: the
        # allocator's own default, no grammar word.
        STRATEGY = "proportional".freeze
        # A re-asked turn's sealed preface is funded as one floor of its own;
        # no template block key can spell it.
        PREFACE_FLOOR = "preface".freeze

        # The newest in-window own preface carries an identical lead prefix,
        # role and text byte for byte. A receipt can need only the environment
        # that preceded its source turn's additional application guidance.
        def carried_lead?(lead, history)
          lead.any? && lead.map { |segment| [segment.role, segment.text] } == history.carried_lead.first(lead.length)
        end

        # A re-asked turn's sealed preface, laid as it was sealed — except a
        # lead the turn relied on the window to carry, laid now when this
        # window no longer carries it (a smaller window, a stated bound), so
        # the model never answers without the lead the turn was asked under.
        def re_laid(preface, history)
          relied = preface.select(&:carried)
          return preface if relied.empty? || carried_lead?(relied.map(&:segment), history)

          preface.map { |entry| entry.with(carried: false) }
        end

        # The segments each block of the template renders, by key: the
        # slots by slot, the template's own inline text macro-rendered from
        # the one source hash, memory, the skills catalog, the caller's
        # lead and tail, the input.
        def named_blocks(template, slots, memory, skills, lead, tail, input, sources)
          inlines = template.inline_blocks.to_h do |block, index|
            [block.key(index), Inline.call(role: block.role, text: Nexus::PromptMacros.render(block.text, sources))]
          end
          slots.by_slot.transform_keys { |slot| "slot:#{slot}" }.merge(inlines,
            "memory" => memory.segments, "skills" => skills.segments, "lead" => lead, "tail" => tail, "input" => input)
        end

        def cost(segments, profile) = segments.sum { |segment| FillCost.segment(segment, profile) }

        # The one allocator call (BudgetAllocator). No window
        # → no allocator: history respects only stated caps (the caller's
        # budget and the template's max_tokens) — alt coerced nil to 0 and
        # starved a windowless model. A required floor the window cannot
        # fund leaves history NOTHING (the subtraction's `clamp(0..)`, kept:
        # the refunded tokens are not free room, the bytes still send) and
        # is reported `floor_unmet` on the evidence; the request sends
        # whole and only the window gate refuses, on the exact count.
        #
        # `history` is the template's floor and cap for the optional child.
        # `explicit` is a STATED budget (the per-turn share, or the
        # template's, through HistoryBudget's flat mapping): the caller's
        # own bound on history with the prompt on top — it may overflow
        # the window, and the wall's timeline compaction is the answer,
        # never a trim to the remainder; the template's `max_tokens`
        # still caps it. With none stated the allocator fits history to
        # the window less the answer room.
        def size(floors:, history:, explicit: nil, profile:, limits:)
          window = limits.planning_input_bound if profile && limits
          if window.nil?
            return Sized.new(history_budget: [explicit, history["max_tokens"]].compact.min,
              allocations: {}, costs: floors)
          end

          children = floors.map { |key, tokens| floor_child(key, tokens) } + [
            BudgetAllocator::Child.new(key: "history", priority: nil, budget: history.slice("min_tokens", "max_tokens")),
          ]
          allocations = BudgetAllocator.call(parent_budget: usable(limits), strategy: STRATEGY, children: children)
            .index_by(&:key)
          funded = allocations.except("history").values.none?(&:exclusion_reason)
          fitted = funded ? allocations.fetch("history").allocated_tokens : 0
          Sized.new(
            history_budget: explicit ? [explicit, history["max_tokens"]].compact.min : fitted,
            allocations: allocations, costs: floors
          )
        end

        def usable(limits)
          window = limits.planning_input_bound
          return window if limits.advisory_input_bound

          [window - ANSWER_ROOM_TOKENS, (window * (1 - ANSWER_ROOM_FRACTION)).floor].max
        end

        # A required floor: exactly its cost, never more (the cap keeps the
        # fill from spilling the remainder back onto it).
        def floor_child(key, tokens)
          BudgetAllocator::Child.new(key: key, priority: nil,
            budget: { "overflow" => "error", "reserved_tokens" => tokens, "max_tokens" => tokens })
        end

        # A lead the window already carried reads `carried`, 0 tokens: its
        # floor was funded, and a funded floor that sends less is valid.
        def evidence(template, placed, sized, history, profile, carried: false)
          template.blocks.each_with_index.map do |block, index|
            key = block.key(index)
            segments = placed.fetch(key)
            allocation = sized.allocations[key]
            historic = key == "history"
            omitted = carried && key == Preface::LEAD
            BlockEvidence.new(
              key: key, index: index, type: block.type, role: segments.first&.role,
              state: omitted ? CARRIED : block_state(segments, allocation, historic ? history : nil),
              tokens: evidence_tokens(key, segments, sized, profile, omitted: omitted),
              allocated_tokens: historic ? sized.history_budget : allocation&.allocated_tokens
            )
          end
        end

        def evidence_tokens(key, segments, sized, profile, omitted:)
          return cost(segments, profile) if key == "history"
          return 0 if omitted

          sized.costs.fetch(key)
        end

        # The allocator's word is its own (`budget_exhausted`); the
        # evidence speaks the state: a floor the window could not fund on
        # bytes that SENT, never "excluded".
        def block_state(segments, allocation, history)
          return "floor_unmet" if history.nil? && allocation&.exclusion_reason
          return (history.selected_count.zero? ? "empty" : "selected") if history

          segments.empty? ? "empty" : "selected"
        end

        # First-occurrence order over the merged tail: the rule
        # `TextInputMessage#upload_public_ids` applies to one message,
        # applied over the list.
        def placed_uploads(segments)
          segments.flat_map(&:attachments).map(&:upload).uniq(&:public_id)
        end

        # Three ways: an entry naming a slot is that slot's override (the
        # block renders it in slot order), the rest are the lead and the
        # tail by position.
        def inline_segments(entries)
          overrides, positioned = Array(entries).partition { |entry| entry["slot"] }
          tail, lead = positioned.partition { |entry| entry["position"] == "tail" }
          [overrides, plain_segments(lead), plain_segments(tail)]
        end

        def plain_segments(entries)
          entries.map { |entry| Segment.plain(entry["role"], entry["text"]) }
        end

        # Adjacent same-role segments join: Anthropic's wire rejects
        # consecutive same-role messages, and regeneration siblings produce
        # exactly that. Parts CONCATENATE in occurrence order — each text
        # stays its own part, never folded with its neighbour, so a message
        # merged here once merges to the same parts every time it is
        # replayed. A segment the loop lane sent ALONE (`Segment#alone`: a
        # round's delivered material, a steer it read) never joins: history
        # renders it as that round's request carried it, and each wire then
        # treats both lanes alike. Nor does a segment carrying replayed
        # reasoning, on either side: every round's reasoning rides as the
        # request that first carried it did, and a merge would move a later
        # segment's thinking ahead of the earlier words or keep one side's
        # items alone.
        # A segment whose placed tail and results trail it stays whole: the
        # next round's words come AFTER those results on the wire, never
        # before — so only the newer segment can bring a tail. A phase and
        # the trace whose origin licenses it travel as ONE pair, from one
        # segment.
        def merge_adjacent_roles(segments)
          segments.each_with_object([]) do |segment, merged|
            last = merged.last
            if merges?(last, segment)
              merged[merged.length - 1] = last.with(
                parts: last.parts + segment.parts,
                call_items: segment.call_items,
                result_items: segment.result_items,
                picture_parts: segment.picture_parts,
                trailing: segment.trailing,
                first_slot: segment.first_slot,
                phase: segment.phase || last.phase,
                trace: segment.phase ? segment.trace : last.trace,
                replay_tokens: last.replay_tokens + segment.replay_tokens
              )
            else
              merged << segment
            end
          end
        end

        def merges?(last, segment)
          last && last.role == segment.role && !last.trailing_items? && !last.alone && !segment.alone &&
            !last.reasoning? && !segment.reasoning?
        end

        # The loop lane's order, byte for byte (Segment#elements).
        def materialize(segments) = segments.flat_map(&:elements)
    end
  end
end
