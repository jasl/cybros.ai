module CybrosAgent
  module Api
    # The Conversation family's wire grammar. It reads STRICTLY where the
    # server guarantees a member and LENIENTLY where the server compacts
    # one away — the conversation presenter `.compact`s every optional
    # field, so absence is the ordinary case here and reading it as an
    # error would break on the first turn without a model.
    module ConversationProjections
      include WorkspaceProjections
      include EventProjections

      CONVERSATION_SUMMARY = {
        public_id: :string,
        title: :optional_string,
        answering_user_public_id: :string,
        archived_at: :optional_string,
        billing_subject: :optional_string,
        parent: [:optional_shape, ConversationParent],
        forked_from_turn_public_id: :optional_string,
        forked_from_variant_public_id: :optional_string,
        side: :boolean,
        active_turn_public_id: :optional_string,
        context_revision: :integer,
        last_activity_at: :optional_string,
        created_at: :string,
        updated_at: :string,
      }.freeze

      # Every model block on this plane is the same three fields, and every
      # one of them is optional: a manual turn names no model.
      CONVERSATION_MODEL = {
        provider_id: :optional_string, model_ref: :optional_string, reasoning_effort: :optional_string,
      }.freeze

      # One principal as a turn or input names it — the access entry's
      # four words; absent only on the kernel's summary turn.
      CONVERSATION_SPEAKER = {
        user_public_id: :string, handle: :string, kind: :string, display_name: :optional_string,
      }.freeze

      TRANSCRIPT_ENVELOPE = %w[
        type turn_public_id variant_public_id agent_loop_public_id task_key turn
      ].freeze

      def conversation_speaker(hash)
        string(hash, "kind") == "ingress" ? shape(IngressSpeaker, hash) : shape(ConversationSpeaker, hash)
      end
      private :conversation_speaker

      SHAPES = {
        ConversationSummary => CONVERSATION_SUMMARY,
        Conversation => CONVERSATION_SUMMARY.merge(
          metadata: :json_object_or_empty,
          input_queue: [:shape, ConversationInputQueue],
          latest_event_cursor: :optional_string,
          # Absent until a turn has settled and reported usage: there is
          # no honest occupancy number before the provider gives one.
          context: [:optional_shape, ConversationContextReport],
          runner: [:optional_shape, RunnerBinding],
          # The carrier, read STRICTLY: the document always carries
          # it (the pack pins the key).
          access: [:shape, ConversationAccess],
          memory_context: :optional_json_object
        ),
        ConversationAccess => { default: :string, entries: [:shapes, ConversationAccessEntry] },
        ConversationAccessEntry => CONVERSATION_SPEAKER.merge(level: :string),
        # The binding, read OPTIONAL on both hosts: the
        # conversation document says `null` when unbound, the loop
        # document compacts the key away — both are "no binding". A
        # binding the server DID report names its executor and its
        # presence, or it is malformed.
        RunnerBinding => {
          executor_public_id: :string, display_name: :optional_string,
          presence: :string, last_seen_at: :optional_string,
        },
        # THE PARENT FACTS, read STRICTLY once present: the
        # block always names the parent; the call's key and the label are
        # nullable members (a reaped spawning loop, an unnamed child).
        ConversationParent => { public_id: :string, spawn_node_key: :optional_string, label: :optional_string },
        ConversationInputQueue => { limit: :integer, held: :integer },
        ConversationContextReport => {
          used_tokens: :optional_integer,
          input_tokens: :optional_integer,
          output_tokens: :optional_integer,
          cache_read_tokens: :optional_integer,
          window_tokens: :optional_integer,
          used_percent: :optional_number,
          as_of_model: [:optional_shape, ConversationModel],
        },
        ConversationModel => CONVERSATION_MODEL,
        ConversationInputList => {
          items: [:shapes, ConversationInput, "inputs"],
          input_queue: [:shape, ConversationInputQueue],
        },
        ConversationInput => {
          public_id: :string,
          queue_position: :integer,
          state: :string,
          kind: :string,
          role: :string,
          delivery_mode: :string,
          expected_steering_loop_public_id: :optional_string,
          context_mode: :optional_string,
          context_options: :json,
          tool_names: :optional_string_list,
          approval_mode: :optional_string,
          # `raw`'s system field, on the row that carries one.
          instructions: :optional_string,
          blocked_reason: :optional_string,
          # Absent on a raw-mode input, whose body is a message list rather
          # than one text.
          text: :optional_string,
          # The pictures beside the words, by presence: a row with none
          # omits the member.
          attachments: [:optional_shapes, UploadRef],
          lock_version: :integer,
          created_at: :string,
          # The source kind, on every input.
          origin: :string,
          sender_conversation_public_id: :optional_string,
          callback_result: [:optional_shape, CallbackResult],
          # The addressee and the author, on every input.
          answering_user_public_id: :string,
          speaker: ->(hash) { conversation_speaker(fetch_hash(hash, "speaker")) },
          # NOT BEFORE this time: the ISO string
          # the kernel holds on a scheduled row; absent on an untimed one.
          # No predicate — a non-nil string is the fact.
          deliver_at: :optional_string,
        },
        ConversationSpeaker => CONVERSATION_SPEAKER,
        IngressSpeaker => { actor_public_id: :string, kind: :string, display_name: :string },
        UploadRef => { public_id: :string, filename: :string, content_type: :string, byte_size: :integer },
        CallbackResult => {
          conversation_public_id: :string, input_public_id: :string, turn_public_id: :string,
          variant_public_id: :string, requester_actor_public_id: :optional_string,
        },
        CallbackSource => {
          input_public_id: :string, origin: :string, sender_conversation_public_id: :optional_string,
          sender_agent_loop_public_id: :optional_string, sender_task_key: :optional_string,
          result: [:shape, CallbackResult],
        },
        ConversationTurnPage => {
          items: [:shapes, ConversationTurn, "turns"],
          before_position: [:optional_integer, "pagination", "before_position"],
          after_position: [:optional_integer, "pagination", "after_position"],
        },
        ConversationTurn => {
          public_id: :string,
          input_public_id: :optional_string,
          callback_sources: [:shapes_or_empty, CallbackSource],
          position: :integer,
          kind: :string,
          role: :string,
          status: :string,
          visibility: :string,
          inherited: :flag,
          origin: :optional_string,
          sender_conversation_public_id: :optional_string,
          sender_agent_loop_public_id: :optional_string,
          sender_task_key: :optional_string,
          # Absent on a turn whose only candidate was concealed, and on a
          # reply that failed before producing one. A variant read out of
          # the ACTIVE slot is active by position, so the server does not
          # repeat the flag there and this supplies it — without that, the
          # one variant a caller is guaranteed to hold would be the one
          # reporting `active?` false.
          active_variant: ->(hash) { optional_shape(ConversationVariant, hash, "active_variant")&.with(active: true) },
          created_at: :string,
          # Who answered, on every kind; who spoke, absent on the kernel's
          # summary.
          answering_user_public_id: :string,
          speaker: ->(hash) { hash["speaker"].nil? ? nil : conversation_speaker(fetch_hash(hash, "speaker")) },
        },
        ConversationVariant => {
          public_id: :string,
          source: :string,
          status: :string,
          model: [:optional_shape, ConversationModel],
          content_preview: :optional_string,
          content: :optional_string,
          # A reply turn's seed — the words that opened it; absent on a message
          # turn, whose `content` is the person's words.
          prompt_text: :optional_string,
          active: :flag,
          # The loop keys ride by presence; the rounds are the
          # loop transcript's rows, carried as the transcript carries them.
          agent_loop_public_id: :optional_string,
          rounds: :optional_json_array,
          attachments: [:optional_shapes, UploadRef],
          world: [:optional_shape, World],
          details_pruned_at: :optional_string,
          memory_context: :optional_json_object,
        },
        # The derived fact: `status` always; the rest by presence, and
        # `checkpoint` the runner's value, parsed once here.
        World => {
          status: :string,
          reason: :optional_string,
          loop: :optional_string,
          runner: :optional_string,
          checkpoint: ->(hash) { checkpoint(hash["checkpoint"]) },
        },
        Checkpoint => {
          hash: :optional_string,
          store: :optional_string,
          skipped: :raw,
          outside: :names,
          ignored: :names,
        },
        ConversationVariantDeck => {
          items: [:shapes, ConversationVariant, "variants"],
          turn_public_id: [:string, "turn", "public_id"],
          turn_inherited: [:flag, "turn", "inherited"],
        },
        ConversationCompaction => {
          turn_public_id: [:string, "turn", "public_id"],
          position: [:integer, "turn", "position"],
          kind: [:string, "turn", "kind"],
          turn_status: [:string, "turn", "status"],
          task_key: ->(body) { optional_hash(body, "task")&.then { |task| string(task, "key") } },
          summary_task_key: :optional_string,
        },
        ConversationRegeneration => {
          turn_public_id: [:string, "turn", "public_id"],
          turn_status: [:string, "turn", "status"],
          variant: [:shape, ConversationVariant],
        },
        # THE ONE MEMBER READ BY NAME on a transcript item is `type`, and
        # everything type-specific rides `payload` untyped. This feed's
        # vocabulary grows — new delta kinds arrive with new capabilities —
        # and a map that enumerated them would refuse the first item it
        # predates rather than hand it to a client that can ignore it.
        TranscriptItem => {
          type: :string,
          turn_public_id: :optional_string,
          variant_public_id: :optional_string,
          agent_loop_public_id: :optional_string,
          task_key: :optional_string,
          turn: [:optional_shape, ConversationTurn],
          payload: ->(hash) { json_snapshot(hash.except(*TRANSCRIPT_ENVELOPE)) },
        },
        MemoryDocument => {
          public_id: :string,
          lock_version: :integer,
          path: :string,
          bytesize: :integer,
          # Null on a plain document, the skill row's line on a `skills/`
          # one — optional on BOTH shapes, so either parses.
          description: :optional_string,
          # Absent from a listing by design, present on a read.
          content: :optional_string,
          written_at: :string,
        },
        PromptDocument => {
          slot: :string,
          role: :string,
          bytesize: :integer,
          version: :integer,
          # Absent from a listing by design, present on a read.
          content: :optional_string,
          written_at: :string,
        },
        # Verbatim: the entries and the options are the sealed payloads as
        # the kernel sent them, frozen snapshots and nothing typed — a
        # debug read's whole value is the bytes.
        SealedRequest => { entries: :json_array, request_options: :json_object },
        ConversationInputEstimate => {
          input_tokens: :integer,
          tokenizer_exact: :boolean,
          catalog_input_token_limit: :optional_integer,
          advisory_input_token_limit: :optional_integer,
          message_count: :integer,
          history: [:shape, ConversationHistoryEvidence],
          # The preview half rides only a `render: true` answer; its
          # presence is the entries' — the count alone carries none.
          rendered: ->(hash) { shape(RenderedEstimate, hash) if hash.key?("entries") },
        },
        RenderedEstimate => {
          mechanism: :string,
          entries: :json_array,
          storage: [:shape, EstimateStorage],
          blocks: [:shapes, ContextBlockEvidence],
          memory: [:shape, MemoryEvidence],
          slots: :json_object,
        },
        EstimateStorage => {
          bytes: :integer,
          bound: :integer,
          within_bound: :boolean,
          # Absent within the bound; the seal's own word over it.
          refusal: :optional_string,
        },
        ContextBlockEvidence => {
          block: :string,
          index: :integer,
          type: :string,
          role: :optional_string,
          state: :string,
          tokens: :integer,
          allocated_tokens: :optional_integer,
        },
        MemoryEvidence => { included: :integer, omitted: :integer },
        ConversationHistoryEvidence => {
          selected: :integer,
          skipped: :integer,
          # Absent when nothing was left out and when nothing was
          # summarized — the two ordinary cases.
          skipped_reason: :optional_string,
          compacted: :count,
        },
      }.freeze

      private

        # THE RUNNER'S CHECKPOINT, parsed once: the
        # kernel carries it VERBATIM — rho-runner's `{hash, store}`, its
        # `{skipped, bytes, files}`, a placeholder — so `raw` is that value
        # and the members are the facts this gem reads off an object; nil
        # for a stored null and for an absent member.
        def checkpoint(value)
          return nil if value.nil?

          shape(Checkpoint, Hash.try_convert(value) || {}).with(raw: json_snapshot(value))
        end

        # The carrier's WRITE shape, one for the create envelope and the
        # later change: `{default:, entries: [{user_public_id: | handle:,
        # level:}]}` — a principal by its id or by its handle (`@lark` or `lark`) — with either key spelling, sent as the wire
        # spells it, in the order given. The words themselves are the
        # kernel's to judge.
        def access_body(access)
          raise ArgumentError, "access must be a Hash of default: and entries:" unless access.is_a?(Hash)

          given = access.transform_keys(&:to_s)
          body = {}
          body["default"] = given["default"] if given.key?("default")
          if given.key?("entries")
            body["entries"] = Array(given["entries"]).map do |entry|
              unless entry.is_a?(Hash)
                raise ArgumentError, "each access entry must be a Hash of user_public_id: (or handle:) and level:"
              end

              entry.transform_keys(&:to_s).slice("user_public_id", "handle", "level")
            end
          end
          body
        end
    end
  end
end
