module CybrosAgent
  module Api
    # Typed projections of a Workspace's Conversations — the multi-turn
    # plane, where a OneShot is a single call.
    #
    # THE SHAPE THAT EXPLAINS THE REST: a conversation holds a TIMELINE of
    # turns; each turn holds a DECK of variants (the original, a
    # regeneration, an edit) and points at exactly one as active; and
    # nothing is authored directly — a caller enqueues an INPUT and the
    # kernel materializes it into a turn at the next boundary. That
    # indirection is the plane's whole concurrency story, so it is
    # deliberately not hidden here.
    #
    # ASYNCHRONOUS BY CONTRACT, like every other creating call in this gem:
    # enqueueing a reply answers 202 with a queued input, and the answer
    # arrives later. There is no blocking spelling — hiding a poll loop
    # inside a method would hide the deadline, the backoff and the rate
    # limit from the only code that can choose them.

    ConversationModel = Data.define(:provider_id, :model_ref, :reasoning_effort) do
      def to_h = super.compact
    end

    # Occupancy from the newest succeeded usage record's PROVIDER-reported
    # tokens — never a local re-count, which is why every member is
    # nullable and the whole block is absent before the first settled turn.
    # `cache_read_tokens` is the provider's own count of the prefix it
    # served from cache — the side conversation's paid confirmation reads
    # it; nil when the provider reported none.
    ConversationContextReport = Data.define(
      :used_tokens, :input_tokens, :output_tokens, :cache_read_tokens,
      :window_tokens, :used_percent, :as_of_model
    ) do
      def to_h = super.compact
    end

    ConversationInputQueue = Data.define(:limit, :held) do
      def full? = held >= limit
    end

    # THE PARENT FACTS of a spawned child: the parent's id,
    # the `spawn` call's key — the id the spawning model read back, nil
    # once the spawning loop is reaped — and the label the spawner gave
    # it (nil when none). One block on both shapes; nil on a top-level row.
    ConversationParent = Data.define(:public_id, :spawn_node_key, :label) do
      def to_h = super.compact
    end

    # What a list surface serves. `active_turn_public_id` is the ONE field
    # that says whether this conversation is busy: present means a reply is
    # running. `answering_user_public_id` is WHO ANSWERS: the profile whose
    # engine replies to every head, whoever posted it — the creator unless
    # another was named at create; a fork copies it. `side` marks a SIDE
    # conversation: a fork at the live head a UI may hide, listed
    # only under `list(side: true)`. `parent` is present on a subagent —
    # the child the kernel's `spawn` minted, listed through `children`.
    ConversationSummary = Data.define(
      :public_id, :title, :answering_user_public_id, :archived_at, :billing_subject,
      :parent, :forked_from_turn_public_id,
      :forked_from_variant_public_id, :side, :active_turn_public_id,
      :context_revision, :last_activity_at, :created_at, :updated_at
    ) do
      def archived? = !archived_at.nil?
      def busy? = !active_turn_public_id.nil?
      def subagent? = !parent.nil?
      def forked? = !forked_from_turn_public_id.nil?
      def side? = side
      def to_h = super.compact
    end

    # One named principal's level on a conversation: self-describing,
    # because the member plane lists no users beside `principals` — the
    # kernel's key, the handle, the kind, the words a person
    # reads, and the level.
    ConversationAccessEntry = Data.define(:user_public_id, :handle, :kind, :display_name, :level)

    # THE ACCESS CARRIER: the level (`full | read | none`) of every
    # principal the entries do not name, and one entry per named principal.
    # The creator and the answerer are `full` by derivation and never
    # appear here. `none` conceals: to such a principal the conversation
    # is absent on every door, never a 403 that admits it exists; `read`
    # reads and is refused `not_authorized` on every write.
    ConversationAccess = Data.define(:default, :entries) do
      def level_for(user_public_id)
        entries.find { |entry| entry.user_public_id == user_public_id }&.level || default
      end
    end

    # The singular read. `latest_event_cursor` is where a follower resumes
    # from without draining the whole replay window first. `runner` is the
    # binding — where the next round's runner-kind calls land,
    # nil when unbound or reaped.
    # `access` is the carrier, always present: the pack pins it.
    Conversation = Data.define(
      :public_id, :title, :answering_user_public_id, :archived_at, :billing_subject,
      :parent, :forked_from_turn_public_id,
      :forked_from_variant_public_id, :side, :active_turn_public_id,
      :context_revision, :last_activity_at, :created_at, :updated_at,
      :metadata, :input_queue, :latest_event_cursor, :context, :runner, :access, :memory_context
    ) do
      def initialize(runner: nil, memory_context: nil, **) = super

      def archived? = !archived_at.nil?
      def busy? = !active_turn_public_id.nil?
      def subagent? = !parent.nil?
      def forked? = !forked_from_turn_public_id.nil?
      def side? = side
      def to_h = super.compact
    end

    # One row in the waiting room. `state` is `pending`, `steering` or
    # `blocked`; a BLOCKED head stops the queue behind it (FIFO is the
    # contract) and carries the reason a caller can act on — the fix is to
    # update the row, which unblocks it.
    # `tool_names` is the turn's tool subset — the declaring profile's flat
    # names this reply runs with — present only when the row names one.
    # `approval_mode` is the turn's TIGHTENING of the declaring profile's
    # approval mode, present only when the row names one.
    # `origin` is the row's SOURCE KIND, on every input: `person` (a
    # human's word), `agent` (a peer's `send`), `task_result` (the mail a
    # background task's answer became) or `child` (a spawned
    # conversation's reply); the kernel's two drain first and are nobody's
    # to change. The sender stamp names the conversation a stamped row
    # came from; absent on a plain word. `answering_user_public_id` is WHO
    # ANSWERS the turn this row opens (the `to:` it was created with, else the conversation's answerer) and `speaker` who
    # wrote it, as the access entry spells a principal. `instructions` is
    # `raw`'s system field as the row carries it (what `create` wrote, read back); nil on an assembled row.
    # A PICTURE A ROW CARRIES: one staged upload as the row shows
    # it — the row's fact, whatever the answering engine read (a text-only
    # engine reads an index line in its place; the picture stays on the
    # row and its kept prompt).
    UploadRef = Data.define(:public_id, :filename, :content_type, :byte_size)

    # The exact formal answer a worker returned. Later edits, regeneration or
    # activation in that conversation do not replace this result's sample.
    CallbackResult = Data.define(:conversation_public_id, :input_public_id, :turn_public_id,
      :variant_public_id, :requester_actor_public_id)

    # One consumed receipt's provenance. A parent summary can read several
    # results without becoming any one source's independently owned answer.
    CallbackSource = Data.define(:input_public_id, :origin, :sender_conversation_public_id,
      :sender_agent_loop_public_id, :sender_task_key, :result) do
      def initialize(sender_conversation_public_id: nil, sender_agent_loop_public_id: nil, sender_task_key: nil, **) = super
      def to_h = super.merge(result: result.to_h).compact
    end

    ConversationInput = Data.define(
      :public_id, :queue_position, :state, :kind, :role, :delivery_mode,
      :context_mode, :context_options, :tool_names, :approval_mode, :instructions, :blocked_reason, :text,
      :attachments, :lock_version, :created_at, :origin, :sender_conversation_public_id,
      :answering_user_public_id, :speaker, :deliver_at, :expected_steering_loop_public_id, :callback_result
    ) do
      def initialize(tool_names: nil, approval_mode: nil, instructions: nil, attachments: nil,
                     sender_conversation_public_id: nil, deliver_at: nil, expected_steering_loop_public_id: nil,
                     callback_result: nil, **) =
        super

      def blocked? = state == "blocked"
      def reply? = kind == "direct_reply"
      def task_result? = origin == "task_result"
      def to_h = super.merge(callback_result: callback_result&.to_h).compact
    end

    ConversationInputList = Data.define(:items, :input_queue) do
      include Enumerable
      def each(&) = items.each(&)
      def length = items.length
    end

    # One candidate answer for a turn. `content` is the full text, present
    # on a settled variant; `content_preview` is the listing's short form
    # and is there either way. A LOOP-BACKED variant (`source:
    # "agent_loop"`) also names the loop that produced it and carries the
    # loop's newest spine rounds as the transcript's rows without their
    # calls (`task_key`, `status`, `text_preview`, `usage`, …; no spine
    # mark, no `calls`, no `branches`), carried untyped; both are absent
    # on every other source.
    # `attachments` are the pictures the variant's prompt carried, as
    # `UploadRef`s in part order; nil when it carried none.
    # THE WORLD A LOOP TOUCHED: a fact the kernel DERIVES off the
    # loop's own rows — `untouched` when no runner-addressed write-kind
    # call was claimed, else `touched` with the writing loop, the executor
    # that CLAIMED its first such call, and that call's `metadata.checkpoint`
    # as a `Checkpoint` — the runner's value verbatim in `raw`, its facts as
    # members — or nil when it stored none. The kernel compares nothing;
    # whether the conversation's bound `runner` can restore it is the
    # caller's comparison of two facts on the reads.
    World = Data.define(:status, :loop, :runner, :checkpoint, :reason) do
      def initialize(loop: nil, runner: nil, checkpoint: nil, reason: nil, **) = super
      def touched? = status == "touched"
      def untouched? = status == "untouched"
      def unavailable? = status == "unavailable"
      def checkpoint_hash = checkpoint&.hash
      def skipped = checkpoint&.skipped
      def to_h = super.merge(checkpoint: checkpoint&.raw).compact
    end

    # THE RUNNER'S CHECKPOINT as the kernel carries it: `raw` is the stored value VERBATIM, and the members
    # are the facts this gem reads off it when it is an object — rho-runner's
    # `{hash, store}`, its `{skipped, bytes, files}` with the `outside` /
    # `ignored` paths a restore could not reach — each nil or empty when the
    # runner stored none (a placeholder value keeps only `raw`).
    Checkpoint = Data.define(:hash, :store, :skipped, :outside, :ignored, :raw) do
      def initialize(hash: nil, store: nil, skipped: nil, outside: [], ignored: [], raw: nil) = super
      def restorable? = !hash.nil?
      def to_h = super.compact
    end

    # A LOOP-BACKED variant also carries `world` — the fact above, absent
    # on every other source like the loop keys beside it.
    # `prompt_text` is a reply turn's seed — the words that opened it
    # — nil on a message turn.
    # `memory_context` is the variant's captured binding selection: nil
    # means default roots, while an empty bindings list means memory is off.
    ConversationVariant = Data.define(
      :public_id, :source, :status, :model, :content_preview, :content, :prompt_text, :active,
      :agent_loop_public_id, :rounds, :attachments, :world, :details_pruned_at, :memory_context
    ) do
      def initialize(prompt_text: nil, agent_loop_public_id: nil, rounds: nil, attachments: nil,
                     world: nil, details_pruned_at: nil, memory_context: nil, **) = super
      def active? = active == true
      def loop_backed? = !agent_loop_public_id.nil?
      def to_h = super.compact.merge(memory_context:)
    end

    # One slot on the timeline. `inherited` means the row belongs to an
    # ANCESTOR conversation and is read through the fork closure — the same
    # `public_id` in the parent and in every descendant, one row, one
    # identity. An inherited turn is read-only from here.
    # WHO SPOKE a turn: `speaker` is the voice a reader
    # attributes it to — a message turn's speaker, a reply turn's
    # ANSWERER (the agent whose engine wrote it, `answering_user_public_id`
    # on every kind) — and nil on the kernel's own summary turn.
    IngressSpeaker = Data.define(:actor_public_id, :kind, :display_name) do
      def agent? = false
    end

    ConversationSpeaker = Data.define(:user_public_id, :handle, :kind, :display_name) do
      def agent? = kind == "agent"
    end

    ConversationTurn = Data.define(
      :public_id, :position, :kind, :role, :status, :visibility, :inherited,
      :origin, :sender_conversation_public_id, :active_variant, :created_at,
      :answering_user_public_id, :speaker, :sender_agent_loop_public_id, :sender_task_key,
      :input_public_id, :callback_sources
    ) do
      def initialize(origin: nil, speaker: nil, sender_agent_loop_public_id: nil, sender_task_key: nil,
                     input_public_id: nil, callback_sources: [].freeze, **) = super
      def inherited? = inherited == true
      def task_result? = origin == "task_result"
      def compaction_summary? = kind == "compaction_summary"
      def text = active_variant&.content
      def to_h = super.merge(callback_sources: callback_sources.map(&:to_h)).compact
    end

    # A position window, with the cursors for the next page in each
    # direction. Positions are the conversation's own ordering and are the
    # only cursors this listing takes.
    ConversationTurnPage = Data.define(:items, :before_position, :after_position) do
      include Enumerable
      def each(&) = items.each(&)
      def length = items.length
    end

    ConversationVariantDeck = Data.define(:items, :turn_public_id, :turn_inherited) do
      include Enumerable
      def each(&) = items.each(&)
      def active = items.find(&:active?)
      def length = items.length
    end

    # What a regeneration answers: the turn is running again and a NEW
    # sample joined the deck beside the original. The original stays
    # active until the new one settles.
    ConversationRegeneration = Data.define(:turn_public_id, :turn_status, :variant)

    # What `compact` answers: the TURN the repair rides — idle, the summary
    # turn (loop-backed, one kernel loop whose only task is the
    # summarizer; it settles through the same converger as any other, so
    # a caller waits for it the same way); with a loop-backed reply
    # running, that reply, and beside it the round repaired (`task_key`)
    # and the summarizer authored for it (`summary_task_key`), both
    # absent between turns.
    ConversationCompaction = Data.define(
      :turn_public_id, :position, :kind, :turn_status, :task_key, :summary_task_key
    ) do
      def initialize(task_key: nil, summary_task_key: nil, **) = super
      def mid_turn? = !task_key.nil?
    end

    # ONE ITEM OFF THE HOSTED REPLAY FEED — a conversation's or a standalone
    # loop's, `resource_type` naming which. `type` is carried verbatim,
    # unknown values included, so a client never has to predate a
    # vocabulary it will meet later. On a `turn_status`, `status` is
    # OPTIONAL: present, the turn moved; absent, a loop-state note
    # (`loop_status` only) and the turn did not.
    ConversationEvent = Data.define(
      :public_id, :sequence, :cursor, :type, :resource_type,
      :resource_public_id, :occurred_at, :payload
    )

    # Sequences are allocated contiguously per host from 1. Retention can
    # leave a gap before returned items; replay cannot recover expired items.
    # `watermark` is the committed allocation head, even after items expire.
    # A consumer behind an empty window needs the host's durable state.
    ConversationEventPage = Data.define(:items, :next_after, :watermark) do
      include Enumerable

      def each(&) = items.each(&)
      def length = items.length
      def empty? = items.empty?

      # Reports a missing prefix, which may require a durable-state refresh.
      def gap_after?(sequence)
        return watermark.to_i > sequence.to_i if items.empty?

        items.first.sequence > sequence.to_i + 1
      end

      # The retained window is exhausted; gap_after? separately tells a
      # consumer whether that replay was sufficient for its projection.
      def caught_up? = next_after.nil? || last_sequence >= watermark.to_i

      def last_sequence = items.last&.sequence.to_i
    end

    # ONE ITEM OFF THE TRANSCRIPT FEED, whichever host and whichever kind.
    # A delta carries its fields in `payload` (`text` for `text_delta`,
    # `kind` + `text` for `reasoning_delta`, `call_id` + `name` or `delta`
    # for the tool-call pair, `reason` for `stream_reset`); a settled turn
    # carries `turn`; a settled loop task carries its `round` or `call`
    # snapshot in `payload` under `task_key`. The correlation keys are read
    # by presence: `turn_public_id`/`variant_public_id` on a conversation
    # host, `agent_loop_public_id`/`task_key` for a loop-backed or standalone
    # round — a direct reply carries no loop keys, a loop host no turn keys.
    #
    # `payload` is a snapshot rather than typed members on purpose: this
    # feed's vocabulary grows, and a client that has to match a closed set
    # of delta types breaks on the first one it predates.
    TranscriptItem = Data.define(
      :type, :turn_public_id, :variant_public_id, :agent_loop_public_id, :task_key,
      :turn, :payload
    ) do
      SETTLED_TYPES = %w[turn round call].freeze

      def settled? = SETTLED_TYPES.include?(type)
      def round? = type == "round"
      def call? = type == "call"
      def reset? = type == "stream_reset"
      def text = payload["text"]
      def to_h = super.compact
    end

    # One durable memory document, whichever door served it — a
    # conversation's or the profile's. `scope` is the path's first segment
    # (`conversation`, `workspace`, `user`). `content` is present on a
    # single read and absent from a listing — the listing selects on
    # `bytesize` precisely so it never has to load what it is only
    # counting.
    #
    # `written_at` IS THE CONTENT'S AGE, not the row's. A forked
    # conversation shares its parent's stored text, so a timestamp taken
    # from the pointer would tell you every inherited document was written
    # at the moment of the fork.
    #
    # `description` is a SKILL row's (a `skills/` path): the line the model reads in its turn's skills block; present
    # on both shapes there, nil on a plain document.
    MemoryDocument = Data.define(:public_id, :lock_version, :path, :bytesize, :description, :content, :written_at) do
      def scope = path.split("/", 2).first
      def skill? = path.split("/", 2).last.to_s.start_with?("skills/")
      def to_h = super.compact
    end

    # One prompt document, whichever door served it — the workspace's
    # `character` or the profile's own slot. `slot` and `role`
    # are the kernel's closed words, carried as read; `version` counts the
    # writes; `content` is present on a single read and absent from a
    # listing, and it is the text AS WRITTEN — the macros unrendered.
    PromptDocument = Data.define(:slot, :role, :bytesize, :version, :content, :written_at) do
      def to_h = super.compact
    end

    # THE BYTES A TURN WAS SENT: exactly the sealed
    # entries — the wire list in position order, the slot blocks and the
    # memory block among them on the assembled lane — and the request
    # options (`instructions` under `raw`, `tools` on a round). Derived
    # from the sealed body, never re-assembled; nothing else rides it.
    SealedRequest = Data.define(:entries, :request_options)

    # A local, pre-send estimate for client-side trim decisions. The
    # Provider stays authoritative; `tokenizer_exact` only says whether the
    # selected profile's declared tokenizer counted this text. `rendered`
    # is the preview half: present only when the estimate was
    # asked for with `render: true`, nil otherwise — and absent from
    # `to_h` then, so the count's own shape is unchanged.
    ConversationInputEstimate = Data.define(
      :input_tokens, :tokenizer_exact, :catalog_input_token_limit,
      :advisory_input_token_limit, :message_count, :history, :rendered
    ) do
      def initialize(rendered: nil, **members) = super

      def tokenizer_exact? = tokenizer_exact
      def rendered? = !rendered.nil?
      def to_h = super.compact
    end

    # THE PREVIEW: what the send would seal, read off the
    # estimate. `mechanism` is the word the compile ran under (`assembly`
    # under the addressee's template or a trial one, else `default`);
    # `entries` are the payloads the seal writes, frozen snapshots exactly
    # as `SealedRequest` carries them — a preview and the send that
    # follows on the same conversation state produce byte-identical
    # entries; `blocks` one row per template block in its order; `slots`
    # the registered documents compiled, `slot => version`.
    RenderedEstimate = Data.define(:mechanism, :entries, :storage, :blocks, :memory, :slots)

    # The seal's ONE measure against the seal's bound. Over it the preview
    # still answers — showing the overflow is the point — with the word the
    # seal refuses with beside the number (`content_too_large`); within it
    # there is no refusal member.
    EstimateStorage = Data.define(:bytes, :bound, :within_bound, :refusal) do
      def within_bound? = within_bound
      def to_h = super.compact
    end

    # One block of the template as the compile saw it: `block` is its key
    # (`slot:<name>`, `inline:<index>`, `memory`, `skills`, `history`,
    # `lead`, `tail`, `input`), `state` one of `selected | empty |
    # floor_unmet | carried`, `tokens` its fill cost, `allocated_tokens` the
    # allocator's grant — nil on a model with no declared window.
    # `floor_unmet` is EVIDENCE: a required block the window could not fund
    # on bytes that still send. `carried` is a lead the window already
    # carries — an identical lead an earlier own turn laid — so it is not
    # laid again and costs 0.
    ContextBlockEvidence = Data.define(:block, :index, :type, :role, :state, :tokens, :allocated_tokens) do
      def selected? = state == "selected"
      def empty? = state == "empty"
      def floor_unmet? = state == "floor_unmet"
      def carried? = state == "carried"
    end

    # The memory block's document counts: what fit, and what was named as
    # omitted (never silently dropped).
    MemoryEvidence = Data.define(:included, :omitted)

    # What assembly did with the timeline. `skipped` is history that was
    # LEFT OUT; `compacted` is history a summary turn STANDS IN FOR — the
    # two are separate because the first is lost and the second is carried.
    ConversationHistoryEvidence = Data.define(
      :selected, :skipped, :skipped_reason, :compacted
    ) do
      def trimmed? = skipped.to_i.positive?
      def compacted? = compacted.to_i.positive?
      def to_h = super.compact
    end
  end
end
