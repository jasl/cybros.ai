module Nexus
  module Contract
    # DERIVED, NOT RESTATED. This used to be a second copy of the family's
    # status mapping, which is how the app came to disagree with its own
    # published contract without any test seeing it. The app's constant is the
    # source; this renders it as the wire renders it.
    COMMON_ERROR_STATUSES = Nexus::FamilyErrors::STATUS
    # The executor doors' own codes, DERIVED where a door keeps a table: the commit door's payload
    # refusals from the ONE settlement renderer (a `resource_link` naming a capture that is not the
    # committer's own is `unknown_result_upload`, the input door's twin), the extend door's
    # conflicts from its controller; the six family conflicts are errors.json's. `not_authorized` is
    # 409 HERE — the loop's principal lost standing, a fact about the row's loop — and 403 on the
    # member doors, which is why it is no family code. `task_not_running` is the commit's conflict
    # on a park not yet dispatched; `not_claimant` the claim-keyed word on the extension and a
    # progress frame alike, `not_bound` the host-keyed frame's; the frame 422s are the progress
    # door's own, `invalid_timeout_ms` the extension's, `invalid_outcome` and `result_too_large` the
    # commit's.
    EXECUTOR_INBOX_ERROR_STATUSES = {
      **AgentAPI::V1::SettlementRendering::PAYLOAD_REFUSALS.to_h { |code| [code.to_s, 422] },
      **AgentAPI::V1::Executors::ExtendsController::CONFLICTS.to_h { |code| [code.to_s, 409] },
      "frame_too_large" => 422,
      "invalid_frame" => 422,
      "invalid_outcome" => 422,
      "invalid_timeout_ms" => 422,
      "not_authorized" => 409,
      "not_bound" => 409,
      "result_too_large" => 422,
      "task_not_running" => 409,
    }.sort.to_h.freeze
    # THE MEMBER PLANE'S WRITE FENCE: every write door of the four families answers 403
    # `not_authorized` to a caller that may browse the host but not write it — an archived-workspace
    # reader, a fenced agent, a principal listed at `read`. One word on every host, so the four
    # tables carry it alike.
    WRITE_FENCE = { "not_authorized" => 403 }.freeze
    # The upload doors: one ingest behind the member, session and executor doors, and the one bytes
    # read on the member plane.
    UPLOAD_ERROR_STATUSES = {
      "content_too_large" => 413,
      "parameter_invalid" => 400,
      "representation_unavailable" => 404,
    }.freeze
    SESSION_ERROR_STATUSES = {
      "invalid_credentials" => 401,
      "local_recovery_required" => 403,
      "password_change_required" => 403,
    }.freeze
    WORKSPACE_ERROR_STATUSES = {
      "invalid_access_mode" => 422,
      **WRITE_FENCE,
      "not_workspace_owner" => 403,
      "provider_incomplete" => 422,
      "provider_not_eligible" => 422,
      "reserved_namespace" => 422,
      "target_not_eligible" => 422,
      "transition_in_progress" => 409,
      "workspace_agent_identifier_mismatch" => 403,
      "workspace_not_active" => 409,
    }.freeze
    # The prompt-document doors' codes: 404 for a slot nobody wrote, 409 for a workspace taking no
    # writes, 422 for the rest.
    PROMPT_DOCUMENT_ERROR_STATUSES = {
      **WRITE_FENCE,
      "prompt_document_not_found" => 404,
      "prompt_slot_unavailable" => 422,
      "prompt_document_too_large" => 422,
      "prompt_document_macro_unknown" => 422,
      "prompt_document_invalid" => 422,
      "workspace_not_active" => 409,
    }.freeze
    # THE MEMORY DOORS' codes: 404 for a document that is not there, 409 for an archived host or an
    # overridden workspace, 422 for every refusal the anchor or the writer names — the four skill
    # words among them. `memory_reserved_prefix` is no HTTP code: it is the tool result a model
    # reads when its `memory_write`, `memory_edit` or `memory_delete` names a `skills/` path.
    MEMORY_ERROR_STATUSES = {
      "parameter_missing" => 400,
      "parameter_invalid" => 400,
      "stale_object" => 409,
      "conversation_archived" => 409,
      "memory_content_invalid" => 422,
      "memory_description_invalid" => 422,
      "memory_document_too_large" => 422,
      "memory_full" => 422,
      "memory_not_found" => 404,
      "memory_overridden" => 409,
      "memory_path_invalid" => 422,
      "memory_read_only" => 403,
      "memory_edit_invalid" => 422,
      "memory_edit_not_found" => 422,
      "memory_edit_ambiguous" => 422,
      "memory_pattern_invalid" => 422,
      "memory_pattern_too_costly" => 422,
      "memory_scope_unavailable" => 422,
      **WRITE_FENCE,
      "skill_description_required" => 422,
      "skill_name_invalid" => 422,
      "skill_scope_unavailable" => 422,
    }.freeze
    STORE_ENTRY_ERROR_STATUSES = {
      "conversation_archived" => 409,
      "entry_limit_reached" => 409,
      "key_taken" => 409,
      **WRITE_FENCE,
      "workspace_agent_identifier_mismatch" => 403,
      "workspace_not_active" => 409,
    }.freeze
    # The OneShot surface's OWN codes — the two the controller authors itself.
    # Every other refusal reaches the wire as an OPEN vocabulary: the create
    # action renders `refusal.to_s` as the code, so the domain's typed symbols
    # cross unlaundered and the set grows whenever a resolver learns a new way
    # to say no. The status is 422 UNLESS the symbol happens to be one of the
    # family's eleven, which carry their published status wherever they are
    # rendered — a storage-bound `content_too_large` from the input body is a
    # 413 on this path as it is on every other. Pinning a snapshot of it here would
    # promise a closed set the code does not have, so the pack pins the
    # SHAPE instead and consumers branch on status plus the code they know.
    ONE_SHOT_ERROR_STATUSES = {
      "not_authorized" => 403,
      "not_terminal" => 409,
    }.freeze
    # THE MODEL PLANE'S OWN CODES: a server whose catalog never compiled
    # answers 503 rather than an empty list; the api-key door's refusal of a
    # lane that authenticates some other way is the service's own word
    # (`ModelProviders::SetAPIKey` / `RemoveAPIKey` answer
    # `material_kind_conflict`, the controller renders it). Every other
    # refusal on the plane is a family code.
    MODEL_ERROR_STATUSES = {
      "material_kind_conflict" => 409,
      "model_plane_unavailable" => 503,
    }.freeze
    # THE TWO PLANES' TABLES, DERIVED (audit wire-17): the workspace base's
    # one refusal map serves both — the conflict list is 409, absence
    # conceals as the family's `not_found`, the write fence is 403 and
    # everything else a service refuses crosses as an OPEN vocabulary at
    # `refusal_default_status` (the one-shot precedent). Beside it the
    # doors' own tables (the compaction door's, the append door's, the ONE
    # settlement renderer's) and the words a door authors in place.
    WORKSPACE_BASE = AgentAPI::V1::BaseController
    SHARED_PLANE_ERROR_STATUSES = {
      **WORKSPACE_BASE::CONFLICT_REFUSALS.to_h { |code| [code.to_s, 409] },
      **WRITE_FENCE,
      # The handoff's two (RunnerBinding), on both hosts' `runner` doors.
      "runner_not_eligible" => 409,
      "runner_not_found" => 404,
      # The debug door on a variant and on a round: nothing was sealed.
      "request_not_sealed" => 404,
    }.freeze
    CONVERSATION_ERROR_STATUSES = {
      **SHARED_PLANE_ERROR_STATUSES,
      # The compaction door's seven and the inputs door's five (the
      # create door's four constants, the parser's `deliver_at_ambiguous`),
      # at the family map's statuses.
      **[
        *%i[
          conversation_busy already_compacted task_not_queued compaction_disabled
          nothing_to_compact compaction_unavailable_under_raw arm_failed
        ],
        ::Conversations::Inputs::Create::NOT_STEERABLE, ::Conversations::Inputs::Create::NOT_SCHEDULABLE,
        ::Conversations::Inputs::Create::IN_PAST, ::Conversations::Inputs::Create::TOO_FAR,
        ::Conversations::Inputs::DeliverAt::AMBIGUOUS,
      ].to_h { |code| [code.to_s, Rack::Utils.status_code(WORKSPACE_BASE::REFUSAL_STATUSES.fetch(code, WORKSPACE_BASE::REFUSAL_DEFAULT_STATUS))] },
      # The words the conversation doors author in place: the turn delete's
      # pin, the cancellation's idle lane, the create door's repeated
      # principal, the estimate's trial-template refusal.
      "descendant_pinned" => 409,
      "not_running" => 409,
      "principal_not_eligible" => 422,
      "prompt_template_invalid" => 422,
    }.sort.to_h.freeze
    AGENT_LOOP_ERROR_STATUSES = {
      **SHARED_PLANE_ERROR_STATUSES,
      **AgentAPI::V1::Workspaces::AgentLoops::TasksController::CONFLICTS.to_h { |code| [code.to_s, 409] },
      # The resolution door renders the settlement's payload refusals as
      # the commit door does; `task_not_running` is its conflict.
      **AgentAPI::V1::SettlementRendering::PAYLOAD_REFUSALS.to_h { |code| [code.to_s, 422] },
      # The create and append doors' own 422s (the two extended envelopes
      # errors.json names beside `stale_revision`, an append conflict, and
      # `conversation_hosted`, the base's); the shell's graph-word refusal.
      "edge_authoring_refused" => 422,
      "graph_authoring_not_available" => 422,
      "invalid_steps" => 422,
      "invalid_outcome" => 422,
      "result_too_large" => 422,
      "task_not_running" => 409,
      "execution_details_pruned" => 410,
    }.sort.to_h.freeze
    ADMIN_USER_ERROR_STATUSES = {
      "administrator_required" => 403,
      "installation_owner" => 409,
      "installation_owner_protected" => 403,
      "last_active_admin" => 409,
      "user_not_active" => 409,
      "user_not_administrable" => 403,
      "workspace_ownership_transfer_required" => 409,
    }.freeze
    OAUTH_ERROR_STATUSES = {
      "access_denied" => 400,
      "authorization_pending" => 400,
      "expired_token" => 400,
      "invalid_client" => 400,
      "invalid_grant" => 400,
      "invalid_request" => 400,
      "slow_down" => 400,
      "temporarily_unavailable" => 429,
      "too_late" => 409,
      "unsupported_grant_type" => 400,
    }.freeze

    class << self
      private

        def errors
          {
            "envelope" => { "error" => %w[code message] },
            # THE FOUR EXTENSIONS of that envelope (audit wire-27), from the
            # one renderer that fences them: a code that carries one more
            # member beside `code` and `message`. The SDK hands the extra
            # members to a caller as `Api::Error#details`.
            "extended_envelopes" => AgentAPI::ExtendedErrorEnvelopes::MEMBERS,
            "family_codes" => COMMON_ERROR_STATUSES.keys,
            "status_by_code" => COMMON_ERROR_STATUSES,
            "valid_fixture" => api_error_fixture("unauthorized", 401),
            "extended_fixture" => api_error_fixture("stale_revision", AGENT_LOOP_ERROR_STATUSES.fetch("stale_revision"),
              members: { "current_revision" => 4 }),
            "rate_limited_fixture" =>
              api_error_fixture("rate_limited", 429, headers: { "Retry-After" => "60" }),
            "server_failure_fixtures" => [
              { "status" => 500, "headers" => {}, "body" => nil },
              { "status" => 502, "headers" => {}, "body" => "Bad Gateway" },
            ],
            "unknown_code_fixture" => unknown_api_error_fixture,
            "unknown_code_behavior" => "classify_by_http_status_and_carry_unknown_code",
          }
        end

        def api_error_fixture(code, status, headers: {}, members: {})
          {
            "status" => status,
            "headers" => headers,
            "body" => {
              "error" => {
                "code" => code,
                "message" => "Fixture error",
                **members,
              },
            },
          }
        end

        def unknown_api_error_fixture
          api_error_fixture(UNKNOWN_VALUE_FIXTURE, 409)
        end

        def oauth_error_fixture(code)
          {
            "status" => OAUTH_ERROR_STATUSES.fetch(code),
            "headers" => {},
            "body" => { "error" => code },
          }
        end
    end
  end
end
