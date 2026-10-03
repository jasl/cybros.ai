module Nexus
  module Contract
    class << self
      private

        # The model plane's public read surface. Two vocabularies a consumer must not close over:
        # WORKLOAD and STATUS both carry unknown values forward rather than rejecting them, because
        # a Nexus that learns a new workload must not break an SDK built before it.
        #
        # TERMINALITY IS NOT A STATUS LOOKUP. `result` is present if and only
        # if the run is finished, which is the property the presenter
        # guarantees and the one a consumer should key on — a client that
        # matched a frozen status list would poll a new terminal status
        # forever.

        # THE MULTI-TURN PLANE'S WIRE CONTRACT. Its shape differs from the
        # OneShot's in one structural way a consumer must not have to
        # discover by trial: NOTHING IS AUTHORED DIRECTLY. A caller enqueues
        # an INPUT, which waits as a durable row, and the kernel
        # materializes it into a TURN at the next boundary. So the
        # projections come in two families — the queue's and the
        # timeline's — and the identifiers they carry are not the same.
        #
        # THE DECK is the second thing to know: a turn holds many VARIANTS
        # (the original, a regeneration, an edit) and points at one as
        # active. Everything additive; only the apex hard-deletes.
        #
        # Every vocabulary here is OPEN by construction. Statuses, kinds,
        # sources, event types and transcript item types all grow, and a
        # consumer matching a frozen set breaks on the first value it
        # predates — which is why the lists are published as fixtures to
        # read, never as sets to enumerate against.
        def conversations
          basic, full, spawned = conversation_presenter_fixtures
          guarded_input = conversation_input_fixture(expected_steering_loop_public_id: "01900000-0000-7000-8000-000000000091")
          input = conversation_input_fixture
          stamped_input = conversation_stamped_input_fixture
          scheduled_input = conversation_scheduled_input_fixture
          turn, variant, variant_row = conversation_turn_fixtures
          stamped_turn = conversation_stamped_turn_fixture
          callback_input, callback_turn, callback_batch_turn = conversation_callback_fixtures
          attached_variant = conversation_attached_variant_fixture(variant_row)
          pruned_variant = conversation_pruned_variant_fixture(variant_row)
          list_fixture = {
            "conversations" => [basic],
            "pagination" => { "next_after" => nil },
          }
          turns_fixture = {
            "turns" => [turn],
            # POSITIONS, not opaque cursors: the timeline is a position
            # window, and a soft-deleted turn keeps its slot forever, so
            # history never renumbers and a position stays a valid cursor.
            "pagination" => { "before_position" => 0, "after_position" => 4 },
          }
          inputs_fixture = {
            "inputs" => [input],
            "input_queue" => { "limit" => 32, "held" => 1 },
          }
          raw_input = conversation_raw_input_fixture
          events_fixture = {
            "events" => [conversation_event_fixture],
            "pagination" => {
              "next_after" => "Y3ZlaS0x",
              "watermark" => 7,
            },
          }
          estimate_fixture = conversation_estimate_fixture
          rendered_estimate_fixture = conversation_rendered_estimate_fixture
          delta = conversation_transcript_delta_fixture
          settled = { "type" => "turn", "turn_public_id" => turn.fetch("public_id"), "turn" => turn }

          {
            "kinds" => ConversationTurn::KINDS.sort,
            # A caller may SEND a subset of what may STAND on the timeline:
            # `compaction_summary` is the kernel's own row and no input
            # kind at all.
            "input_kinds" => ConversationInput::KINDS.sort,
            "valid_guarded_input_fixture" => { "input" => guarded_input },
            "valid_ingress_input_fixture" => { "input" => input.merge(
              "origin" => "agent", "speaker" => stringify_keys(Conversations::TurnProjection.actor_speaker(contract_ingress_actor))) },
            "valid_ingress_turn_fixture" => turn.merge("kind" => "message", "role" => "user",
              "speaker" => stringify_keys(Conversations::TurnProjection.actor_speaker(contract_ingress_actor))),
            "roles" => ConversationTurn::ROLES.sort,
            "statuses" => ConversationTurn::STATUSES.sort,
            "terminal_statuses" => ConversationTurn::TERMINAL_STATUSES.sort,
            "visibilities" => ConversationTurn::VISIBILITIES.sort,
            "variant_sources" => ConversationTurnVariant::SOURCES.sort,
            "input_states" => ConversationInput::STATES.sort,
            "delivery_modes" => ConversationInput::DELIVERY_MODES.sort,
            "context_modes" => ConversationInput::CONTEXT_MODES.sort,
            "event_types" => ConversationEventItem::ITEM_TYPES.sort,
            "event_retention_days" => 30,
            "list_envelope" => list_fixture.keys,
            "singular_envelope" => %w[conversation],
            "turns_envelope" => turns_fixture.keys,
            "inputs_envelope" => inputs_fixture.keys,
            "events_envelope" => events_fixture.keys,
            "estimate_envelope" => estimate_fixture.keys,
            "realtime_path" => "/agent_api/v1/cable",
            "realtime_envelope" => %w[event],
            "realtime_items" => AgentAPI::V1::ConversationEventsChannel::FEEDS.keys,
            "realtime_default_items" => "events",
            "realtime_lifecycle_event_types" =>
              RealtimeEvents::Broadcast::LIFECYCLE_TYPES.fetch("conversation"),
            # TWO SHAPES ON ONE FEED. A delta says what a turn is SAYING and routes by
            # `turn_public_id`; the settled item says what it SETTLED as and carries the same
            # projection a timeline page serves, under the same key. A loop-backed turn's rounds
            # settle here too, as `round` and `call` under `task_key`. Neither is durable — this
            # feed is a tail, and `turns` is the recovery path.
            "transcript_items" => Conversations::TranscriptStream::ITEM_TYPES,
            # THE PROGRESS FEED'S VOCABULARY, ONCE: the executor's two words (`executor.md`
            # "Progress") and the kernel's own three, on one feed under one envelope.
            "progress_frame_types" => Executors::Progress::TYPES + Conversations::ProgressStream::KERNEL_TYPES,
            "progress_frame_envelope" => %w[frame],
            "transcript_delta_envelope" => delta.keys,
            "transcript_settled_envelope" => settled.keys,
            "transcript_routing_key" => "turn_public_id",
            "pagination" => list_fixture.fetch("pagination").keys,
            "basic_projection" => basic.keys,
            "full_projection_adds" => full.keys - basic.keys,
            # THE UNION of every shape the presenter compacts (audit
            # wire-19): the assembled row, the raw row (`instructions`, no
            # `text`), the stamped and blocked row (`sender_conversation_public_id`,
            # `blocked_reason`), the scheduled row (`deliver_at`) — a
            # consumer reads the optional ones by presence.
            "input_projection" => (input.keys | raw_input.keys | stamped_input.keys | scheduled_input.keys | guarded_input.keys | callback_input.keys),
            # The input compacts hard: only these survive every shape.
            # A raw-mode row carries no `text` (its body is a message
            # list), and only a blocked row carries a reason.
            "input_projection_required" =>
              %w[public_id queue_position state kind role delivery_mode origin lock_version created_at],
            "turn_projection" => (turn.keys | stamped_turn.keys | callback_turn.keys),
            # `active_variant` is absent on a turn whose only candidate was
            # concealed and on a reply that failed before producing one, so
            # a consumer reads it by presence.
            "turn_projection_required" =>
              %w[public_id position kind role status visibility created_at],
            # The loop-backed variant, the one carrying pictures (`attachments`) and a reply turn's
            # (`prompt_text`, the seed's words) — every optional key by presence.
            "variant_projection" => (variant.keys | attached_variant.keys | pruned_variant.keys | turn.fetch("active_variant").keys),
            "variant_projection_required" => %w[public_id source status memory_context],
            # THE WORLD FACT (C7): on a loop-backed variant and on the fork
            # answer — `status` always, the other three on `touched`,
            # `checkpoint` only when the runner's metadata carried the key.
            "world_projection" => %w[status loop runner checkpoint reason],
            "world_projection_required" => %w[status],
            "world_statuses" => %w[untouched touched unavailable],
            "world_fixtures" => world_fixtures,
            # A loop-backed variant's round row: the loop transcript's
            # thread row without its calls, its branches and the spine
            # mark — the loop's own transcript route is where the calls are.
            "variant_round_projection" => variant.fetch("rounds").first.keys,
            "context_projection" => full.fetch("context").keys,
            "input_queue_projection" => inputs_fixture.fetch("input_queue").keys,
            "estimate_projection" => estimate_fixture.fetch("context_estimate").keys,
            "estimate_history_projection" =>
              estimate_fixture.dig("context_estimate", "history").keys,
            # `skipped` is history LEFT OUT; `compacted` is history a
            # summary turn STANDS IN FOR. Separate members because the
            # first is lost and the second is carried — a consumer that
            # summed them would report a repair as a loss.
            "estimate_history_projection_required" => %w[selected skipped],
            # THE PREVIEW: the same estimate with `render: true` — the entries the seal would write,
            # the storage line from the one measure, the thin evidence per block. `excluded` is not
            # a state: a floor the window cannot fund still sends; `carried` is a lead the window
            # already carries, laid once and costing nothing again.
            "rendered_estimate_projection" => rendered_estimate_fixture.fetch("context_estimate").keys,
            "rendered_estimate_storage_projection" =>
              rendered_estimate_fixture.dig("context_estimate", "storage").keys,
            "rendered_estimate_storage_projection_required" => %w[bytes bound within_bound],
            "rendered_estimate_block_projection" =>
              rendered_estimate_fixture.dig("context_estimate", "blocks").first.keys,
            "rendered_estimate_block_states" => %w[selected empty floor_unmet carried],
            "rendered_estimate_mechanisms" => %w[assembly default],
            "event_projection" => events_fixture.fetch("events").first.keys,
            # `side=1` lists side conversations only; the default hides them.
            "list_filters" => %w[order after limit side],
            "list_directions" => AgentAPI::KeysetPagination::DIRECTIONS.keys,
            "error_codes" => CONVERSATION_ERROR_STATUSES.keys,
            "error_statuses" => CONVERSATION_ERROR_STATUSES,
            # The service words the base's map renders as the family's
            # `not_found`: absence conceals, on every door alike.
            "absence_refusals" => WORKSPACE_BASE::ABSENCE_REFUSALS.map(&:to_s),
            # Every refusal outside the table crosses as an OPEN vocabulary
            # (the service's own symbol is the code) at this status.
            "refusal_default_status" => 422,
            "turns_filters" => %w[after_position before_position limit],
            "events_filters" => %w[after limit],
            "events_pagination" => events_fixture.fetch("pagination").keys,
            "events_default_limit" =>
              AgentAPI::V1::Workspaces::Conversations::EventsController::DEFAULT_LIMIT,
            "events_max_limit" =>
              AgentAPI::V1::Workspaces::Conversations::EventsController::MAX_LIMIT,
            "turns_default_limit" =>
              AgentAPI::V1::Workspaces::Conversations::TurnsController::DEFAULT_LIMIT,
            "turns_max_limit" =>
              AgentAPI::V1::Workspaces::Conversations::TurnsController::MAX_LIMIT,
            "valid_list_fixture" => list_fixture,
            "valid_fixture" => { "conversation" => full },
            # THE PARENT FACTS: a spawned child's listing row — `parent` as one block; `/children`
            # lists these.
            "spawned_child_fixture" => spawned,
            "parent_projection" => spawned.fetch("parent").keys,
            "valid_turns_fixture" => turns_fixture,
            "valid_inputs_fixture" => inputs_fixture,
            # A `raw` row, as the create door answers it: the SDK's `instructions:` reads back on
            # the row it wrote; a raw body is a message list, so `text` is absent.
            "valid_raw_input_fixture" => { "input" => raw_input },
            "valid_input_fixture" => { "input" => input },
            "valid_callback_input_fixture" => { "input" => callback_input },
            "valid_callback_turn_fixture" => callback_turn,
            "valid_callback_batch_turn_fixture" => callback_batch_turn,
            # A STAMPED, BLOCKED ROW: a peer's `send` carries the sender stamp, and a blocked head
            # names its reason.
            "valid_stamped_input_fixture" => { "input" => stamped_input },
            # A SCHEDULED ROW (item 12): `deliver_at` by presence — the ISO
            # time the kernel holds; an untimed row omits the member.
            "scheduled_input_fixture" => { "input" => scheduled_input },
            # A STAMPED TURN: the settled row a peer's word became.
            "valid_stamped_turn_fixture" => stamped_turn,
            # A VARIANT CARRYING PICTURES: the descriptors beside the words, in part order — a
            # direct reply, no loop.
            "valid_pruned_variant_fixture" => { "variant" => pruned_variant },
            "expired_request_error_fixture" => api_error_fixture("execution_details_pruned", 410),
            "valid_attached_variant_fixture" => { "variant" => attached_variant },
            "valid_error_fixture" =>
              api_error_fixture("conversation_busy", CONVERSATION_ERROR_STATUSES.fetch("conversation_busy")),
            "unknown_error_fixture" => unknown_api_error_fixture,
            "valid_variants_fixture" => {
              "variants" => [variant],
              "turn" => { "public_id" => turn.fetch("public_id"), "inherited" => false },
            },
            "valid_variant_fixture" => { "variant" => variant },
            "bound_memory_variant_fixture" => { "variant" => stringify_keys(AgentAPI::ConversationPresenter.variant(
              variant_row.with(memory_context: { "bindings" => [
                { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
                { "name" => "group", "scope" => "conversation", "access" => "read",
                  "conversation_public_id" => "01900000-0000-7000-8000-000000000072" },
              ] }), body: nil, active: true
            )) },
            "disabled_memory_variant_fixture" => { "variant" => stringify_keys(AgentAPI::ConversationPresenter.variant(
              variant_row.with(memory_context: { "bindings" => [] }), body: nil, active: true
            )) },
            # THE ACCESS CARRIER'S WRITE SHAPE: the create envelope's `access` and the body of `PUT
            # …/access` are the same object — a default and the named entries, each
            # `{user_public_id, level}`; the levels are the default's words.
            "memory_context_request" => {
              "memory_context" => { "bindings" => [
                { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
                { "name" => "group", "scope" => "conversation", "access" => "read",
                  "conversation_public_id" => "01900000-0000-7000-8000-000000000072" },
              ] },
            },
            "memory_context_disabled_request" => { "memory_context" => { "bindings" => [] } },
            "memory_context_default_request" => { "memory_context" => nil },
            "access_levels" => Conversation.access_defaults.keys.sort,
            "valid_access_request" => {
              "access" => {
                "default" => "none",
                "entries" => [{ "user_public_id" => "01900000-0000-7000-8000-000000000004", "level" => "full" }],
              },
            },
            # THE DEBUG DOOR: `GET …/variants/{id}/request` answers exactly the sealed entries and
            # the request_options — the slots as the first system-role item, then the input.
            "valid_request_fixture" => sealed_request_fixture(
              entries: [
                { "role" => "system", "parts" => [{ "type" => "text", "text" => "You are in Shared with Ada." }] },
                { "role" => "user", "parts" => [{ "type" => "text", "text" => "What is next?" }] },
              ],
              request_options: { "temperature" => 0.2 }
            ),
            # A regeneration sibling of a direct reply is an inference
            # sample: no loop, so none of the loop keys; the turn's seed
            # rides it (`prompt_text`), cloned onto the newborn candidate.
            "valid_regeneration_fixture" => {
              "turn" => { "public_id" => turn.fetch("public_id"), "status" => "running" },
              "variant" => variant.merge("source" => "inference", "status" => "running", "active" => false)
                .except("content", "content_preview", "agent_loop_public_id", "rounds", "world"),
            },
            # A regeneration sibling of a LOOP-BACKED turn is born with its OWN loop: the 202
            # carries the new loop's id — the feed's correlation key — its one round (the origin's
            # seed rebuilt, queued for the scheduler: `waiting`) and its `world` (`untouched`:
            # nothing has run), through the one deck read; the turn's seed rides it too, cloned onto
            # the newborn candidate.
            "valid_loop_backed_regeneration_fixture" => {
              "turn" => { "public_id" => turn.fetch("public_id"), "status" => "running" },
              "variant" => stringify_keys(AgentAPI::ConversationPresenter.variant(
                variant_row, body: nil, active: false,
                loop: AgentAPI::ConversationPresenter::LoopBlock.new(
                  agent_loop_public_id: "01900000-0000-7000-8000-0000000000b2",
                  rounds: [{ task_key: "r1", status: "waiting", visibility: "visible" }],
                  world: world_fixtures.fetch("untouched")
                ),
                prompt: CONTRACT_BODY_TYPE.new(effective_text: "What is next?")
              )).except("content_preview")
                .merge("public_id" => "01900000-0000-7000-8000-000000000092", "status" => "running"),
            },
            # THE FORK ANSWER: the child's full read beside `world` for the fork point — the first
            # runner-addressed write-kind call claimed strictly ABOVE the turn in the source's
            # reach, every candidate and every concealed turn counted; a replay answers the same
            # value off the receipt.
            "valid_fork_fixture" => { "conversation" => full, "world" => world_fixtures.fetch("touched") },
            "valid_events_fixture" => events_fixture,
            "valid_estimate_fixture" => estimate_fixture,
            "valid_rendered_estimate_fixture" => rendered_estimate_fixture,
            "valid_transcript_delta_fixture" => { "event" => delta },
            "valid_transcript_settled_fixture" => { "event" => settled },
            # THE KERNEL'S OWN PROGRESS FRAMES: three facts no row or settled item carries at their
            # instant — an attempt dialled, a tool row live with its name, the claimant — on the
            # host's `progress` feed beside the executor's, rendered by the producer's own pure
            # builders so the SDK's ProgressFrame is settled against the kernel's bytes. No
            # `executor_public_id` on the first two: only the claim names one.
            "valid_round_started_frame_fixture" => {
              "frame" => Conversations::ProgressStream.round_started_frame(
                keys: { agent_loop_public_id: "01900000-0000-7000-8000-000000000031", task_key: "r3" },
                spine: true, attempt: 1, model: "dev/mock-text", request_bytes: 41_208, at: "2026-09-14T10:00:00.250Z"
              ),
            },
            "valid_step_started_frame_fixture" => {
              "frame" => Conversations::ProgressStream.step_started_frame(
                keys: { agent_loop_public_id: "01900000-0000-7000-8000-000000000031", task_key: "r4t0" },
                tool_name: "read_file", status: "dispatched", at: "2026-09-14T10:00:00.250Z"
              ),
            },
            "valid_step_claimed_frame_fixture" => {
              "frame" => Conversations::ProgressStream.step_claimed_frame(
                keys: { agent_loop_public_id: "01900000-0000-7000-8000-000000000031", task_key: "r4t0" },
                tool_name: "read_file", executor_public_id: "01900000-0000-7000-8000-000000000030",
                at: "2026-09-14T10:00:00.250Z"
              ),
            },
            "valid_realtime_subscription_fixture" => {
              "channel" => "AgentAPI::V1::ConversationEventsChannel",
              "workspace_id" => "01900000-0000-7000-8000-000000000001",
              "conversation_id" => basic.fetch("public_id"),
              "items" => "events",
            },
            # The three specimens a consumer must carry through rather than
            # match: a kind, a status and a transcript type it predates.
            "unknown_turn_kind_fixture" => turn.merge("kind" => "future_kind"),
            "unknown_status_fixture" => turn.merge("status" => "future_status"),
            "unknown_event_type_fixture" =>
              conversation_event_fixture.merge("type" => "future_item"),
            "unknown_transcript_item_fixture" => {
              "type" => "future_delta",
              "turn_public_id" => turn.fetch("public_id"),
              "variant_public_id" => variant.fetch("public_id"),
              "future_field" => "carried through",
            },
            "unknown_realtime_items_fixture" => {
              "channel" => "AgentAPI::V1::ConversationEventsChannel",
              "workspace_id" => "01900000-0000-7000-8000-000000000001",
              "conversation_id" => basic.fetch("public_id"),
              "items" => "future_feed",
            },
          }
        end
    end
  end
end
