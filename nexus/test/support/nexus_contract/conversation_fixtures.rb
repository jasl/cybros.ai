module Nexus
  module Contract
    class << self
      private

        # Rendered through the REAL presenter with duck-typed stand-ins, so
        # a presenter change lands here rather than in a consumer.
        def conversation_presenter_fixtures
          turn_type = Data.define(:public_id)
          conversation_type = Data.define(
            :public_id, :title, :answering_user, :archived_at, :billing_subject_key,
            :parent_conversation_public_id, :spawn_node, :spawn_label, :forked_from_turn_public_id,
            :forked_from_variant_public_id, :side, :active_turn, :context_revision,
            :last_activity_at, :created_at, :updated_at, :metadata,
            :input_queue_limit, :memory_context
          ) do
            def subagent? = !parent_conversation_public_id.nil?
          end
          conversation = conversation_type.new(
            public_id: "01900000-0000-7000-8000-000000000070",
            title: "Planning",
            # The answering profile: the pack's Human, answering its own conversation — the default
            # the door writes.
            answering_user: Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000003"),
            archived_at: nil,
            billing_subject_key: nil,
            parent_conversation_public_id: nil,
            spawn_node: nil,
            spawn_label: nil,
            forked_from_turn_public_id: nil,
            forked_from_variant_public_id: nil,
            # A side conversation says `side: true`; the working row the pack shows is not one.
            side: false,
            active_turn: turn_type.new(public_id: "01900000-0000-7000-8000-000000000071"),
            context_revision: 4,
            last_activity_at: Time.utc(2026, 8, 31, 0, 0, 12),
            created_at: Time.utc(2026, 8, 31),
            updated_at: Time.utc(2026, 8, 31, 0, 0, 12),
            metadata: { "topic" => "planning" },
            memory_context: nil,
            input_queue_limit: 32
          )
          basic = stringify_keys(AgentAPI::ConversationPresenter.basic(conversation))
          # A SPAWNED CHILD: `parent` is one block — the parent's id, the `spawn` call's key (nil
          # once the spawning loop is reaped), the label (nil when none was given) — on the listing
          # shape, so `/children` prints it; nil on every top-level row.
          child = conversation.with(
            public_id: "01900000-0000-7000-8000-000000000072",
            title: nil,
            answering_user: Data.define(:public_id).new(public_id: "01900000-0000-7000-8000-000000000005"),
            parent_conversation_public_id: conversation.public_id,
            spawn_node: Data.define(:node_key).new(node_key: "r2t0"),
            spawn_label: "reviewer",
            active_turn: nil,
            context_revision: 1
          )
          spawned = stringify_keys(AgentAPI::ConversationPresenter.basic(child))
          full = basic.merge(
            "metadata" => { "topic" => "planning" },
            "memory_context" => nil,
            "input_queue" => { "limit" => 32, "held" => 1 },
            "latest_event_cursor" => "Y3ZlaS03",
            # THE BINDING IS READABLE: where the next round's runner-kind calls land — always
            # rendered, nil when unbound or reaped (`agent_loops.json`'s request loop shows a bound
            # one).
            "runner" => nil,
            # PROVIDER TRUTH, never a local re-count — and absent entirely
            # until a turn has settled and reported usage.
            "context" => {
              "used_tokens" => 3_120,
              "input_tokens" => 2_900,
              "output_tokens" => 220,
              # The provider's cache-read count; absent when the provider reported none.
              "cache_read_tokens" => 2_100,
              "window_tokens" => 128_000,
              "used_percent" => 2.4,
              "as_of_model" => { "provider_id" => "dev", "model_ref" => "text" },
            },
            # THE ACCESS CARRIER: the default for everyone the entries do not name, and the named
            # entries — self-describing, since the member plane lists no users. The creator and the
            # answerer are derived and never rows.
            "access" => {
              "default" => "read",
              "entries" => [
                { "user_public_id" => "01900000-0000-7000-8000-000000000004", "handle" => "reviewer",
                  "kind" => "human", "display_name" => "Reviewer", "level" => "full" },
              ],
            }
          )
          [basic, full, spawned]
        end

        CONTRACT_INPUT_TYPE = Data.define(
          :public_id, :queue_position, :state, :kind, :role, :delivery_mode,
          :context_mode, :context_options, :tool_names, :approval_mode, :instructions, :blocked_reason,
          :host, :text, :lock_version, :created_at, :origin, :sender_conversation_public_id,
          :speaker_actor, :answering_user, :content_body, :deliver_at, :expected_steering_loop_public_id, :callback_result
        ) do
          def initialize(content_body: nil, deliver_at: nil, expected_steering_loop_public_id: nil, callback_result: nil, **) = super
        end

        # A body as the presenter reads it: its words and the pictures it binds — the `ContentBody`
        # surface the projections call.
        CONTRACT_BODY_TYPE = Data.define(:effective_text, :upload_parts) do
          def initialize(upload_parts: [], **) = super
        end

        # One bound picture, as `ContentUpload` answers the four facts.
        CONTRACT_UPLOAD_TYPE = Data.define(:public_id, :filename, :content_type, :byte_size)

        def contract_picture
          CONTRACT_UPLOAD_TYPE.new(
            public_id: "01900000-0000-7000-8000-0000000000c1", filename: "diagram.png",
            content_type: "image/png", byte_size: 184_213
          )
        end

        # The `raw` row: no slots, no text — the entries are the body — and
        # the wire's own system field on the row.
        def conversation_raw_input_fixture
          stringify_keys(AgentAPI::ConversationPresenter.input(CONTRACT_INPUT_TYPE.new(
            host: Conversation.new,
            speaker_actor: Actor.new(user: contract_person),
            answering_user: contract_agent,
            public_id: "01900000-0000-7000-8000-000000000081",
            queue_position: 1,
            state: "pending",
            kind: "direct_reply",
            role: "user",
            delivery_mode: "queue",
            context_mode: "raw",
            context_options: {},
            tool_names: nil,
            approval_mode: nil,
            instructions: "Be brief.",
            blocked_reason: nil,
            text: nil,
            lock_version: 0,
            created_at: Time.utc(2026, 8, 31, 0, 0, 5),
            origin: "person",
            sender_conversation_public_id: nil
          )))
        end

        def conversation_callback_fixtures
          sources = ["1", "2"].map do |suffix|
            result = {
              "conversation_public_id" => "01900000-0000-7000-8000-0000000001#{suffix}0",
              "input_public_id" => "01900000-0000-7000-8000-0000000001#{suffix}1",
              "turn_public_id" => "01900000-0000-7000-8000-0000000001#{suffix}2",
              "variant_public_id" => "01900000-0000-7000-8000-0000000001#{suffix}3",
              "requester_actor_public_id" => "01900000-0000-7000-8000-0000000000a1",
            }
            { "input_public_id" => "01900000-0000-7000-8000-0000000001#{suffix}4", "origin" => "child",
              "sender_conversation_public_id" => result.fetch("conversation_public_id"),
              "sender_agent_loop_public_id" => "01900000-0000-7000-8000-0000000001#{suffix}5",
              "sender_task_key" => "01900000-0000-7000-8000-0000000001#{suffix}6", "result" => result }
          end
          [conversation_input_fixture(callback_result: sources.first.fetch("result")),
            conversation_callback_turn_fixture(sources.first(1)), conversation_callback_turn_fixture(sources)]
        end

        def conversation_callback_turn_fixture(sources)
          source = sources.last
          _, _, variant = conversation_turn_fixtures
          turn = CONTRACT_TURN_TYPE.new(public_id: "01900000-0000-7000-8000-000000000074",
            input_public_id: source.fetch("input_public_id"), callback_sources: sources,
            position: 6, kind: "direct_reply", role: "assistant", status: "completed", origin: "child",
            sender_conversation_public_id: sources.one? ? source.fetch("sender_conversation_public_id") : nil,
            sender_agent_loop_public_id: sources.one? ? source.fetch("sender_agent_loop_public_id") : nil,
            sender_task_key: sources.one? ? source.fetch("sender_task_key") : nil,
            created_at: Time.utc(2026, 10, 2), speaker_actor: Actor.new(user: contract_person), answering_user: contract_agent)
          stringify_keys(AgentAPI::ConversationPresenter.turn_block(turn, "visible", false, variant,
            CONTRACT_BODY_TYPE.new(effective_text: "The independent work is complete.")))
        end

        # A peer's word, blocked at the head: `origin: agent`, the sender stamp, and the reason the
        # drain stopped on it.
        def conversation_stamped_input_fixture
          stringify_keys(AgentAPI::ConversationPresenter.input(CONTRACT_INPUT_TYPE.new(
            host: Conversation.new,
            speaker_actor: Actor.new(user: contract_agent),
            answering_user: contract_agent,
            public_id: "01900000-0000-7000-8000-000000000082",
            queue_position: 2,
            state: "blocked",
            kind: "message",
            role: "user",
            delivery_mode: "queue",
            context_mode: "assembled",
            context_options: {},
            tool_names: nil,
            approval_mode: nil,
            instructions: nil,
            blocked_reason: "loop_held",
            text: "Review is done; one orphan method in lib/x.rb.",
            lock_version: 0,
            created_at: Time.utc(2026, 8, 31, 0, 0, 6),
            origin: "agent",
            sender_conversation_public_id: "01900000-0000-7000-8000-000000000072"
          )))
        end

        # A SCHEDULED ROW (owner 2026-09-15, item 12): a person's word
        # accepted now with a "not before" — `deliver_at`, the ISO time the
        # kernel holds, present only on a row that carries one; the row
        # waits `pending` at its arrival position, invisible to the drain
        # until then.
        def conversation_scheduled_input_fixture
          stringify_keys(AgentAPI::ConversationPresenter.input(CONTRACT_INPUT_TYPE.new(
            host: Conversation.new,
            speaker_actor: Actor.new(user: contract_person),
            answering_user: contract_agent,
            public_id: "01900000-0000-7000-8000-000000000083",
            queue_position: 3,
            state: "pending",
            kind: "direct_reply",
            role: "user",
            delivery_mode: "queue",
            context_mode: "assembled",
            context_options: {},
            tool_names: nil,
            approval_mode: nil,
            instructions: nil,
            blocked_reason: nil,
            text: "Check the deploy.",
            lock_version: 0,
            created_at: Time.utc(2026, 8, 31, 0, 0, 7),
            origin: "person",
            sender_conversation_public_id: nil,
            deliver_at: Time.utc(2026, 8, 31, 0, 20, 0)
          )))
        end

        def conversation_input_fixture(expected_steering_loop_public_id: nil, callback_result: nil)
          stringify_keys(AgentAPI::ConversationPresenter.input(CONTRACT_INPUT_TYPE.new(
            # A conversation host renders the assembly fields; a loop host omits them.
            host: Conversation.new,
            # WHO SPOKE and WHO ANSWERS: the author's voice and the addressee — here a person's row
            # addressed to an agent.
            speaker_actor: Actor.new(user: contract_person),
            answering_user: contract_agent,
            public_id: "01900000-0000-7000-8000-000000000080",
            queue_position: 0,
            state: expected_steering_loop_public_id ? "steering" : "pending",
            kind: "direct_reply",
            role: "user",
            delivery_mode: expected_steering_loop_public_id ? "steer" : "queue",
            expected_steering_loop_public_id: expected_steering_loop_public_id,
            callback_result: callback_result,
            context_mode: "assembled",
            # An inline entry naming a slot overrides that slot's registered document for the turn;
            # `slot` and `position` never together.
            context_options: { "history" => { "max_entries" => 20 },
                               "inline" => [{ "slot" => "character", "text" => "For this turn: be terse." }] },
            # The turn's tool subset, present only when the row names one; the turn's approval
            # tightening likewise.
            tool_names: %w[read_file],
            approval_mode: "ask",
            # `raw`'s system field; absent on an assembled row.
            instructions: nil,
            blocked_reason: nil,
            text: "What is next?",
            # THE PICTURES BESIDE THE WORDS: one descriptor per occurrence in part order; absent
            # when the row binds none.
            content_body: CONTRACT_BODY_TYPE.new(effective_text: "What is next?", upload_parts: expected_steering_loop_public_id ? [] : [contract_picture]),
            lock_version: 0,
            created_at: Time.utc(2026, 8, 31, 0, 0, 4),
            # `origin` is the source kind, always present: `person` on a
            # human's word, `agent` on a peer's, `task_result`/`child` on
            # the kernel's own mail; the sender stamp rides only the
            # stamped rows (conversations.md).
            origin: callback_result ? "child" : "person",
            sender_conversation_public_id: callback_result&.fetch("conversation_public_id")
          )))
        end

        CONTRACT_VARIANT_TYPE = Data.define(
          :public_id, :source, :status, :provider_id, :model_ref,
          :reasoning_effort, :content_preview, :details_pruned_at, :memory_context
        )

        CONTRACT_TURN_TYPE = Data.define(
          :public_id, :position, :kind, :role, :status,
          :origin, :sender_conversation_public_id, :created_at,
          :speaker_actor, :answering_user, :sender_agent_loop_public_id, :sender_task_key, :input_public_id, :callback_sources
        ) do
          def initialize(sender_agent_loop_public_id: nil, sender_task_key: nil, input_public_id: nil, callback_sources: [], **) = super
        end

        # A peer's message as a settled turn: `origin: agent` and the sender stamp on the row; no
        # candidate, no reply.
        def conversation_stamped_turn_fixture
          stringify_keys(AgentAPI::ConversationPresenter.turn_block(
            CONTRACT_TURN_TYPE.new(
              public_id: "01900000-0000-7000-8000-000000000073",
              position: 5,
              kind: "message",
              role: "user",
              status: "completed",
              origin: "agent",
              sender_conversation_public_id: "01900000-0000-7000-8000-000000000072",
              sender_agent_loop_public_id: "01900000-0000-7000-8000-0000000000b1",
              sender_task_key: "r2t0",
              created_at: Time.utc(2026, 8, 31, 0, 0, 14),
              speaker_actor: Actor.new(user: contract_agent),
              answering_user: contract_agent
            ),
            "visible", false, nil, nil, nil
          ))
        end

        # A direct reply's candidate whose seed carried a picture: the descriptors ride the variant;
        # no loop, so none of its keys.
        def conversation_attached_variant_fixture(variant_row)
          body = CONTRACT_BODY_TYPE.new(effective_text: "The diagram shows two services.",
            upload_parts: [contract_picture])
          stringify_keys(AgentAPI::ConversationPresenter.variant(
            variant_row.with(public_id: "01900000-0000-7000-8000-000000000093", source: "inference",
              content_preview: "The diagram shows two services."),
            body: body, active: true
          ))
        end

        def conversation_turn_fixtures
          variant_type = CONTRACT_VARIANT_TYPE
          turn_type = CONTRACT_TURN_TYPE
          body_type = CONTRACT_BODY_TYPE
          # THE LOOP-BACKED VARIANT: a reply the kernel loop produced names its loop and carries the
          # loop's newest SPINE rounds as the transcript's rows without their calls — both ADDITIVE,
          # absent on every other source, read by presence. `content` is the deliverable's answer as
          # on a direct reply. The round row is the loop transcript's thread row (agent_loops.md)
          # minus `calls`, `branches` and the spine mark: a turn shows rounds, never the graph.
          # Pinned against a real round in AgentLoops::TranscriptTest.
          variant_row = variant_type.new(
            public_id: "01900000-0000-7000-8000-000000000091",
            source: "agent_loop",
            status: "completed",
            provider_id: "dev",
            model_ref: "text",
            reasoning_effort: "medium",
            content_preview: "Here is the plan.", details_pruned_at: nil, memory_context: nil
          )
          body = body_type.new(effective_text: "Here is the plan.")
          # THE WORLD: a loop-backed variant also carries what its loop did to the files, DERIVED
          # off the loop's rows — here the first runner-addressed write-kind call a runner claimed,
          # and that call's `metadata.checkpoint` VERBATIM (rho-runner's `{hash, store}`); the four
          # shapes are `world_fixtures`.
          loop = AgentAPI::ConversationPresenter::LoopBlock.new(
            agent_loop_public_id: "01900000-0000-7000-8000-0000000000b1",
            rounds: [{
              task_key: "r1",
              status: "completed",
              visibility: "visible",
              text_preview: "Here is the plan.",
              text_bytes: 17,
              usage: { input_tokens: 812, output_tokens: 40, total_tokens: 852 },
              started_at: "2026-08-31T00:00:02Z",
              completed_at: "2026-08-31T00:00:11Z",
            }],
            world: world_fixtures.fetch("touched")
          )
          # THE SEED: the words that opened the reply ride its variant as `prompt_text` on every
          # door — the deck, the swipe, the view state, the 202, the turns page — the same words the
          # sealed request carries.
          seed = body_type.new(effective_text: "What is next?")
          variant = stringify_keys(
            AgentAPI::ConversationPresenter.variant(variant_row, body: body, active: true, loop: loop, prompt: seed)
          )
          turn = stringify_keys(AgentAPI::ConversationPresenter.turn_block(
            turn_type.new(
              public_id: "01900000-0000-7000-8000-000000000071",
              position: 4,
              kind: "direct_reply",
              role: "assistant",
              status: "completed",
              origin: "person",
              sender_conversation_public_id: nil,
              created_at: Time.utc(2026, 8, 31, 0, 0, 12),
              # THE SETTLED GROUP TURN: a person's question answered by the agent it addressed —
              # `speaker` on a reply turn is its answerer, and `answering_user_public_id` is the
              # same id.
              speaker_actor: Actor.new(user: contract_person),
              answering_user: contract_agent
            ),
            "visible", false, variant_row, body, loop, seed
          ))
          [turn, variant, variant_row]
        end

        def conversation_pruned_variant_fixture(variant_row)
          loop = AgentAPI::ConversationPresenter::LoopBlock.new(
            agent_loop_public_id: "01900000-0000-7000-8000-0000000000b1",
            rounds: [], world: AgentLoops::World.unavailable,
            details_pruned_at: Time.utc(2026, 9, 29)
          )
          stringify_keys(AgentAPI::ConversationPresenter.variant(variant_row,
            body: CONTRACT_BODY_TYPE.new(effective_text: "Here is the plan."),
            prompt: CONTRACT_BODY_TYPE.new(effective_text: "What is next?"), active: true, loop: loop))
        end

        # The four values `world` takes on the wire: nothing claimed; touched with the runner's
        # `{hash, store}`; touched with the runner's `{skipped, bytes, files}` (it declined to
        # capture); touched with a placeholder — the kernel stores ANY value verbatim and reads only
        # whether a `hash` is present. `loop` is the writing loop, `runner` the executor that
        # CLAIMED its first write-kind call (the claimant column, never a runner-reported id).
        def world_fixtures
          touched = {
            "status" => "touched",
            "loop" => "01900000-0000-7000-8000-0000000000b1",
            "runner" => "019f0000-0000-7000-8000-000000000301",
          }
          {
            "untouched" => { "status" => "untouched" },
            "unavailable" => stringify_keys(AgentLoops::World.unavailable),
            "touched" => touched.merge("checkpoint" => {
              "hash" => "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "store" => "3f0c9d2a7b1e5c68",
            }),
            "skipped" => touched.merge("checkpoint" => {
              "skipped" => "tree_too_large", "bytes" => 402_653_184, "files" => 12_047,
            }),
            "placeholder" => touched.merge("checkpoint" => "c1"),
          }
        end

        # The two principals the conversation fixtures name — never rows,
        # the presenter reads only their four words.
        def contract_person
          User.new(public_id: "01900000-0000-7000-8000-0000000000a1", handle: "ada", kind: :human,
            display_name: "Ada")
        end

        def contract_agent
          User.new(public_id: "01900000-0000-7000-8000-0000000000a2", handle: "lark", kind: :agent,
            display_name: "Lark")
        end

        def conversation_event_fixture
          {
            "public_id" => "01900000-0000-7000-8000-0000000000a1",
            "sequence" => 7,
            "cursor" => "Y3ZlaS03",
            "type" => "turn_status",
            "resource" => {
              "type" => "conversation",
              "public_id" => "01900000-0000-7000-8000-000000000070",
            },
            "occurred_at" => "2026-08-31T00:00:12.000Z",
            "payload" => {
              "turn_public_id" => "01900000-0000-7000-8000-000000000071",
              "turn_kind" => "direct_reply",
              "variant_public_id" => "01900000-0000-7000-8000-000000000091",
              "status" => "completed",
              "variant_status" => "completed",
            },
          }
        end

        def conversation_transcript_delta_fixture
          {
            "type" => "text_delta",
            "turn_public_id" => "01900000-0000-7000-8000-000000000071",
            "variant_public_id" => "01900000-0000-7000-8000-000000000091",
            "text" => "Here is ",
          }
        end

        def conversation_estimate_fixture
          {
            "context_estimate" => {
              "input_tokens" => 812,
              "tokenizer_exact" => true,
              "catalog_input_token_limit" => 128_000,
              "advisory_input_token_limit" => 100_000,
              "message_count" => 5,
              "history" => {
                "selected" => 4,
                "skipped" => 12,
                "skipped_reason" => "budget_exceeded",
                "compacted" => 9,
              },
            },
          }
        end

        # Through the presenter over a fabricated estimate, so the pack's
        # shape IS the projection's (the one-shot estimate's precedent).
        def conversation_rendered_estimate_fixture
          entries = [
            { "role" => "system", "parts" => [{ "type" => "text", "text" => "You are the room's narrator." }] },
            { "role" => "user", "parts" => [{ "type" => "text", "text" => "first\n\nand this question" }] },
          ]
          # The `skills` row: the block type the default template renders after memory, empty here
          # as memory is.
          blocks = [
            ["slot:system_prompt", 0, "slot", "system", "selected", 6, 6],
            ["memory", 1, "memory", nil, "empty", 0, 0],
            ["skills", 2, "skills", nil, "empty", 0, 0],
            ["history", 3, "history", "user", "selected", 3, 99_991],
            ["input", 4, "input", "user", "selected", 4, 4],
          ].map do |key, index, type, role, state, tokens, allocated|
            Conversations::ContextAssembly::BlockEvidence.new(
              key: key, index: index, type: type, role: role, state: state, tokens: tokens, allocated_tokens: allocated
            )
          end
          estimate = Conversations::ContextEstimate::Estimate.new(
            input_tokens: 812, tokenizer_exact: true, catalog_input_token_limit: 128_000,
            advisory_input_token_limit: 100_000, message_count: 2, selection: nil,
            history_selected: 4, history_skipped: 12, history_skipped_reason: "budget_exceeded",
            history_compacted: 9,
            rendered: Conversations::ContextEstimate::Rendered.new(
              mechanism: "assembly", entries: entries, storage: ContentBodies::Measure.call(entries), blocks: blocks,
              memory: Conversations::ContextAssembly::MemoryBlock::Block.empty,
              slots: Conversations::ContextAssembly::SlotBlocks::Blocks.new(
                segments: [], versions: { "system_prompt" => 4 }, by_slot: {}
              )
            )
          )

          { "context_estimate" => stringify_keys(AgentAPI::ContextEstimatePresenter.full(estimate, render: true)) }
        end
    end
  end
end
