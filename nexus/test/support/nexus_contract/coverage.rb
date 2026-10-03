module Nexus
  module Contract
    class << self
      private

        # Machine-readable completeness index. A reference is
        # `<pack file>#/<JSON pointer>`. Consumers act only on entries that
        # name them, but every pointer must resolve everywhere: the Nexus and
        # E2E suites walk all four sections as a completeness check.
        def coverage
          {
            "protocol_versions" => {
              "contract_pack" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "meta.json#/contract",
                unknown: "meta.json#/unknown_version_fixture",
                behavior: "reject"
              ),
            },
            "closed_discriminators" => {
              "oauth.client_id" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/agent_authorization_request/client_id",
                unknown: "oauth.json#/unknown_client_request",
                behavior: "reject_as_invalid_client"
              ),
              "oauth.grant_type" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/device_token_request/grant_type",
                unknown: "oauth.json#/unknown_grant_request",
                behavior: "reject_as_unsupported_grant_type"
              ),
              "oauth.token_response.plane" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/valid_agent_token_fixture/plane",
                unknown: "oauth.json#/unknown_plane_fixture",
                behavior: "reject_response"
              ),
              "oauth.token_type" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/valid_agent_token_fixture/token_type",
                unknown: "oauth.json#/unknown_token_type_fixture",
                behavior: "reject_response"
              ),
              "platform.session.kind" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "sessions.json#/valid_show_fixture/session/kind",
                unknown: "sessions.json#/unknown_kind_fixture",
                behavior: "carry_unknown"
              ),
              "platform.session.token_type" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "sessions.json#/valid_create_fixture/token_type",
                unknown: "sessions.json#/unknown_token_type_fixture",
                behavior: "reject_response"
              ),
              "profile.member.kind" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "profiles.json#/agent_api/member/kind",
                unknown: "profiles.json#/unknown_member_kind_fixture",
                behavior: "carry_unknown"
              ),
              "profile.member.role" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "profiles.json#/agent_api/member/role",
                unknown: "profiles.json#/unknown_member_role_fixture",
                behavior: "carry_unknown"
              ),
              "agent_profile.credential.plane" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "profiles.json#/agent_api/credential/plane",
                unknown: "profiles.json#/unknown_credential_plane_fixture",
                behavior: "carry_unknown"
              ),
              # The named definition's scope: `instance | steward`, carried as a word.
              "named_agent.scope" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "profiles.json#/named_agents_fixture/agents/0/scope",
                unknown: "profiles.json#/unknown_named_agent_scope_fixture/agents/0/scope",
                behavior: "carry_unknown"
              ),
              "platform_profile.credential_plane" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "profiles.json#/platform_api_token/credential_plane",
                unknown: "profiles.json#/unknown_platform_credential_plane_fixture",
                behavior: "carry_unknown_without_granting_authority"
              ),
              "executor.kind" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "task_executors.json#/valid_fixture/executor/kind",
                unknown: "task_executors.json#/unknown_kind_fixture",
                behavior: "carry_unknown"
              ),
              "executor.status" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "task_executors.json#/valid_fixture/executor/status",
                unknown: "task_executors.json#/unknown_status_fixture",
                behavior: "carry_unknown"
              ),
              # DISCOVERY'S ONE FILTER: the two machine kinds; an agent address binds nothing and
              # asking for it is the caller's 400.
              "executor.discovery.kind.filter" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "task_executors.json#/valid_discovery_kind_filter_request",
                unknown: "task_executors.json#/unknown_discovery_kind_filter_request",
                behavior: "reject_as_parameter_invalid"
              ),
              # THE MODEL PLANE'S THREE WORDS: the resolver's refusal on a
              # row that will not run, the pricing projection's state, the
              # lane's credential kind — each the kernel's to grow, carried.
              "model.unavailable_reason" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "models.json#/unavailable_fixture/unavailable_reason",
                unknown: "models.json#/unknown_unavailable_reason_fixture/unavailable_reason",
                behavior: "carry_unknown"
              ),
              "model.pricing.state" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "models.json#/valid_fixture/models/0/pricing/state",
                unknown: "models.json#/unknown_pricing_state_fixture/pricing/state",
                behavior: "carry_unknown"
              ),
              "model_provider.credentials" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "models.json#/valid_provider_fixture/model_provider/credentials",
                unknown: "models.json#/unknown_credentials_fixture/credentials",
                behavior: "carry_unknown"
              ),
              "inbox_task.kind" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "executor_inbox.json#/valid_fixture/tasks/0/kind",
                ask: "executor_inbox.json#/ask_fixture",
                unknown: "executor_inbox.json#/unknown_kind_fixture",
                behavior: "carry_unknown"
              ),
              # The kernel's scope stamp: present on an overridden THE RESULT GRAMMAR'S BLOCK KINDS:
              # `text` and `resource_link`, closed on the REQUEST side — a block of any other kind
              # is the kernel's typed refusal, never carried.
              "executor_inbox.content.kind" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "executor_inbox.json#/commit_link_fixture/content/1/type",
                unknown: "executor_inbox.json#/unknown_content_kind_fixture/content/1/type",
                behavior: "reject_as_unsupported_content_kind"
              ),
              # kernel row alone; the "unknown" case is its absence.
              "inbox_task.scope" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "executor_inbox.json#/overridden_fixture/scope",
                unknown: "executor_inbox.json#/valid_fixture/tasks/0",
                behavior: "absent_is_nil"
              ),
              # The progress door's two closed words: the key kind the poster chooses and the frame
              # type the kernel stamps.
              "progress.key_kind" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "executor_inbox.json#/progress/key_kinds/0",
                unknown: "executor_inbox.json#/unknown_progress_key_kind_fixture",
                behavior: "reject_as_invalid_frame"
              ),
              # The feed's ONE word list: the executor's two and the kernel's three, rendered under
              # conversations; the unknown specimen is the door's own frame with a type it predates.
              "progress.frame_type" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "conversations.json#/progress_frame_types/0",
                unknown: "executor_inbox.json#/unknown_progress_frame_type_fixture",
                behavior: "carry_unknown"
              ),
              "workspace.state.response" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "workspaces.json#/valid_fixture/workspace/state",
                unknown: "workspaces.json#/unknown_state_response_fixture",
                behavior: "carry_unknown"
              ),
              "workspace.state.filter" => coverage_entry(
                consumers: %w[nexus],
                valid: "workspaces.json#/valid_state_filter_request",
                unknown: "workspaces.json#/unknown_state_filter_request",
                behavior: "reject_as_parameter_invalid"
              ),
              # THE KEYSET GRAMMAR'S DIRECTION, read on every listing of the
              # family: `asc` or `desc`, a stranger word the caller's 400.
              "list.order.filter" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "workspaces.json#/valid_order_request",
                unknown: "workspaces.json#/unknown_order_request",
                behavior: "reject_as_parameter_invalid"
              ),
              "workspace.access_mode.response" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "workspaces.json#/valid_fixture/workspace/access_mode",
                unknown: "workspaces.json#/unknown_access_mode_fixture",
                behavior: "carry_unknown"
              ),
              "workspace.access_mode.command" => coverage_entry(
                consumers: %w[nexus],
                valid: "workspaces.json#/valid_access_mode_request",
                unknown: "workspaces.json#/unknown_access_mode_request",
                behavior: "reject_as_invalid_access_mode"
              ),
              "workspace.creator.kind" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "workspaces.json#/valid_full_fixture/workspace/creator/kind",
                unknown: "workspaces.json#/unknown_creator_kind_fixture",
                behavior: "carry_unknown"
              ),
              # BOTH CARRY. A Nexus that learns a sixth workload, or an
              # execution status this SDK predates, must not break a client
              # built before it — so neither vocabulary is closed on the read
              # side, and terminality is read from `result`, not from a status
              # list a consumer froze. The list FILTER is the opposite: an
              # unknown workload there is a caller typo the server should say
              # so about rather than silently answer nothing for.
              "one_shot.workload.response" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "one_shots.json#/valid_fixture/one_shot/workload",
                unknown: "one_shots.json#/unknown_workload_fixture",
                behavior: "carry_unknown"
              ),
              "one_shot.workload.filter" => coverage_entry(
                consumers: %w[nexus],
                valid: "one_shots.json#/valid_workload_filter_request",
                unknown: "one_shots.json#/unknown_workload_filter_request",
                behavior: "reject_as_parameter_invalid"
              ),
              "one_shot.status" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "one_shots.json#/valid_fixture/one_shot/status",
                unknown: "one_shots.json#/unknown_status_fixture",
                behavior: "carry_unknown"
              ),
              "one_shot.event.type" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "one_shots.json#/valid_event_fixture/type",
                unknown: "one_shots.json#/unknown_event_type_fixture",
                behavior: "carry_unknown"
              ),
              "one_shot.realtime.items" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "one_shots.json#/valid_realtime_subscription_fixture/items",
                unknown: "one_shots.json#/unknown_realtime_items_fixture/items",
                behavior: "reject_subscription"
              ),
              # THE CONVERSATION PLANE'S OPEN VOCABULARIES. A turn KIND
              # grows the moment the kernel gains a row of its own — which
              # is exactly what `compaction_summary` was — and a client
              # built before it must render the timeline rather than
              # refuse it. Status and event type carry for the same
              # reason. The realtime feed name is the opposite: an
              # unknown one is a caller typo and the subscription is
              # rejected rather than confirmed onto a stream that will
              # never deliver.
              "conversation.turn.kind" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "conversations.json#/valid_turns_fixture/turns/0/kind",
                unknown: "conversations.json#/unknown_turn_kind_fixture",
                behavior: "carry_unknown"
              ),
              "conversation.turn.status" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "conversations.json#/valid_turns_fixture/turns/0/status",
                unknown: "conversations.json#/unknown_status_fixture",
                behavior: "carry_unknown"
              ),
              "scheduled_job.status" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "scheduled_jobs.json#/valid_fixture/scheduled_job/status",
                unknown: "scheduled_jobs.json#/unknown_status_fixture",
                behavior: "carry_unknown"
              ),
              "scheduled_job.rule.response" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "scheduled_jobs.json#/valid_fixture/scheduled_job/rule/kind",
                unknown: "scheduled_jobs.json#/unknown_rule_fixture",
                behavior: "carry_unknown"
              ),
              "conversation.event.type" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "conversations.json#/valid_events_fixture/events/0/type",
                unknown: "conversations.json#/unknown_event_type_fixture",
                behavior: "carry_unknown"
              ),
              # THE TRANSCRIPT FEED'S OWN GROWTH. Its item types arrive
              # with new capabilities, so the projection reads `type` and
              # nothing else by name — everything type-specific rides an
              # untyped payload, and an item this SDK predates reaches the
              # caller whole rather than raising.
              "conversation.transcript.type" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "conversations.json#/valid_transcript_delta_fixture/event/type",
                unknown: "conversations.json#/unknown_transcript_item_fixture",
                behavior: "carry_unknown"
              ),
              "conversation.realtime.items" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "conversations.json#/valid_realtime_subscription_fixture/items",
                unknown: "conversations.json#/unknown_realtime_items_fixture/items",
                behavior: "reject_subscription"
              ),
              # THE PICTURE'S OWN VOCABULARY carries: a node's status and
              # kind are the kernel's words, and a drawing that refused a
              # park word it predates would go blank on the deploy that adds one.
              "agent_loop.graph.node.status" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "agent_loops.json#/valid_graph_fixture/nodes/0/status",
                unknown: "agent_loops.json#/unknown_node_status_fixture",
                behavior: "carry_unknown"
              ),
              "admin_user.kind" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "admin_users.json#/valid_removal_fixture/user/kind",
                unknown: "admin_users.json#/unknown_kind_fixture",
                behavior: "carry_unknown"
              ),
              "admin_user.role" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "admin_users.json#/valid_removal_fixture/user/role",
                unknown: "admin_users.json#/unknown_role_fixture",
                behavior: "carry_unknown"
              ),
              "admin_user.status" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "admin_users.json#/valid_removal_fixture/user/status",
                unknown: "admin_users.json#/unknown_status_fixture",
                behavior: "carry_unknown"
              ),
              # THE SLOT AND ROLE WORDS. Both fixtures are RESPONSES, so the behavior these entries
              # declare is the READER's: a slot or role a client predates is carried as a word,
              # never refused (the SDK's own pin). The doors' write side is the other half and
              # refuses a stranger word by name (`prompt_slot_unavailable`,
              # `prompt_document_invalid`) — the `.response`/`.command` split every other closed
              # vocabulary here keeps.
              "prompt_document.slot" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "prompt_documents.json#/valid_fixture/prompt_document/slot",
                unknown: "prompt_documents.json#/unknown_slot_fixture",
                behavior: "carry_unknown"
              ),
              "prompt_document.role" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "prompt_documents.json#/valid_fixture/prompt_document/role",
                unknown: "prompt_documents.json#/unknown_role_fixture",
                behavior: "carry_unknown"
              ),
            },
            "terminal_classes" => {
              "oauth.authorization_loss" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/terminal_error_fixture",
                unknown: "oauth.json#/unknown_error_fixture",
                behavior: "known_terminal_errors_end_authorization_unknown_error_is_server_failure"
              ),
              "oauth.cancellation_consumed" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/consumed_cancellation_fixture",
                unknown: "oauth.json#/unknown_error_fixture",
                behavior: "too_late_maps_to_consumed_unknown_response_raises"
              ),
              "executor.revoked" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "task_executors.json#/terminal_status_fixture",
                unknown: "task_executors.json#/unknown_status_fixture",
                behavior: "carry_terminal_or_unknown_status_without_inventing_authority"
              ),
              "workspace.deleted" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "workspaces.json#/terminal_state_fixture",
                unknown: "workspaces.json#/unknown_state_response_fixture",
                behavior: "carry_terminal_or_unknown_state_without_inventing_browsability"
              ),
            },
            "stable_error_families" => {
              "api.common" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "errors.json#/valid_fixture",
                unknown: "errors.json#/unknown_code_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "oauth.machine" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "oauth.json#/valid_error_fixture",
                unknown: "oauth.json#/unknown_error_fixture",
                behavior: "unknown_error_is_server_failure"
              ),
              "platform.session" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "sessions.json#/valid_error_fixture",
                unknown: "sessions.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "agent.workspaces" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "workspaces.json#/valid_error_fixture",
                unknown: "workspaces.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "agent.store_entries" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "store_entries.json#/valid_error_fixture",
                unknown: "store_entries.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "agent.memory" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "memory_documents.json#/valid_error_fixture",
                unknown: "memory_documents.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "agent.conversations" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "conversations.json#/valid_error_fixture",
                unknown: "conversations.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "agent.agent_loops" => coverage_entry(
                consumers: %w[e2e nexus sdk],
                valid: "agent_loops.json#/valid_error_fixture",
                unknown: "agent_loops.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              "agent.models" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "models.json#/valid_error_fixture",
                unknown: "models.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
              # THE FOUR EXTENDED ENVELOPES: a code that carries one more
              # member beside `code` and `message`, read by name; a
              # consumer carries the envelope whole and classifies by status.
              "api.extended_envelope" => coverage_entry(
                consumers: %w[nexus sdk],
                valid: "errors.json#/extended_fixture",
                unknown: "errors.json#/unknown_code_fixture",
                behavior: "classify_by_http_status_and_carry_details"
              ),
              "platform.admin_user_removal" => coverage_entry(
                consumers: %w[e2e nexus],
                valid: "admin_users.json#/valid_error_fixture",
                unknown: "admin_users.json#/unknown_error_fixture",
                behavior: "classify_by_http_status_and_carry_unknown_code"
              ),
            },
          }
        end

        # `extra` names further fixtures a value may point at (`ask:` → the
        # ask row); consumers walk `valid_fixture`/`unknown_fixture` by name.
        def coverage_entry(consumers:, valid:, unknown:, behavior:, **extra)
          {
            "consumers" => consumers,
            "valid_fixture" => valid,
            "unknown_fixture" => unknown,
            "unknown_behavior" => behavior,
            **extra.to_h { |name, reference| ["#{name}_fixture", reference] },
          }
        end
    end
  end
end
