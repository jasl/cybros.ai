use cybros_agent::types::{member as m, platform as p};
use serde::de::DeserializeOwned;
use serde_json::Value;
fn fixture(family: &str) -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../contracts/nexus/v1")
        .join(format!("{family}.json"));
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}
fn decode<T: DeserializeOwned>(family: &str, key: &str, pointer: &str, errors: &mut Vec<String>) {
    let pack = fixture(family);
    let value = pack
        .get(key)
        .expect(key)
        .pointer(pointer)
        .unwrap_or_else(|| panic!("{key}{pointer}"))
        .clone();
    if let Err(e) = serde_json::from_value::<T>(value) {
        errors.push(format!("{family}.{key}{pointer}: {e}"));
    }
}
#[test]
fn shared_wire_documents_decode_with_their_typed_fields() {
    let mut e = vec![];
    for key in [
        "valid_full_fixture",
        "unknown_access_mode_fixture",
        "unknown_creator_kind_fixture",
    ] {
        decode::<m::Workspace>(
            "workspaces",
            key,
            if key == "valid_full_fixture" {
                "/workspace"
            } else {
                ""
            },
            &mut e,
        );
    }
    decode::<m::WorkspaceSummary>("workspaces", "valid_list_fixture", "/workspaces/0", &mut e);
    decode::<m::WorkspaceMessaging>(
        "workspaces",
        "valid_messaging_fixture",
        "/messaging",
        &mut e,
    );
    for key in ["valid_fixture", "speaker_memory_conversation_fixture"] {
        decode::<m::Conversation>("conversations", key, "/conversation", &mut e);
    }
    for key in [
        "valid_input_fixture",
        "valid_raw_input_fixture",
        "valid_ingress_input_fixture",
        "valid_steps_input_fixture",
    ] {
        decode::<m::Input>("conversations", key, "/input", &mut e);
    }
    for key in [
        "valid_ingress_turn_fixture",
        "valid_reference_turn_fixture",
        "unknown_turn_kind_fixture",
        "unknown_status_fixture",
    ] {
        decode::<m::Turn>("conversations", key, "", &mut e);
    }
    for key in [
        "valid_variant_fixture",
        "valid_pruned_variant_fixture",
        "valid_fallback_variant_fixture",
    ] {
        decode::<m::Variant>("conversations", key, "/variant", &mut e);
    }
    decode::<m::EventPage>("conversations", "valid_events_fixture", "", &mut e);
    decode::<m::Event>("conversations", "unknown_event_type_fixture", "", &mut e);
    decode::<m::InputEstimate>(
        "conversations",
        "valid_estimate_fixture",
        "/context_estimate",
        &mut e,
    );
    decode::<m::InputEstimate>(
        "conversations",
        "valid_rendered_estimate_fixture",
        "/context_estimate",
        &mut e,
    );
    decode::<m::InputMaterialization>(
        "conversations",
        "valid_materialization_fixture",
        "/materialization",
        &mut e,
    );
    decode::<m::ConversationRegeneration>(
        "conversations",
        "valid_regeneration_fixture",
        "",
        &mut e,
    );
    decode::<m::VariantDeck>("conversations", "valid_variants_fixture", "", &mut e);
    decode::<m::InputList>("conversations", "valid_inputs_fixture", "", &mut e);
    decode::<m::TurnPage>("conversations", "valid_turns_fixture", "", &mut e);
    for key in ["valid_request_run_fixture", "valid_run_backed_fixture"] {
        decode::<m::Run>("runs", key, "/run", &mut e);
    }
    for key in [
        "valid_task_detail_fixture",
        "valid_toolless_task_detail_fixture",
        "valid_tool_task_detail_fixture",
        "valid_ask_task_detail_fixture",
    ] {
        decode::<m::TaskDetail>("runs", key, "/task", &mut e);
    }
    decode::<m::RunGraph>("runs", "valid_graph_fixture", "", &mut e);
    decode::<m::RunTranscript>("runs", "valid_thread_page_fixture", "", &mut e);
    decode::<m::RunPhases>("runs", "valid_phases_fixture", "", &mut e);
    for key in [
        "valid_fixture",
        "valid_queued_fixture",
        "valid_image_fixture",
        "valid_embedding_fixture",
        "valid_failed_fixture",
        "valid_switched_fixture",
    ] {
        decode::<m::InferenceRequest>("inference_requests", key, "/inference_request", &mut e);
    }
    decode::<m::InferenceRequestEventPage>(
        "inference_requests",
        "valid_events_fixture",
        "",
        &mut e,
    );
    decode::<m::InferenceRequestInputEstimate>(
        "inference_requests",
        "valid_input_estimate_fixture",
        "/input_estimate",
        &mut e,
    );
    for key in [
        "ask_fixture",
        "approval_fixture",
        "skill_fixture",
        "unknown_kind_fixture",
    ] {
        decode::<m::InboxTask>("executor_inbox", key, "", &mut e);
    }
    decode::<m::ClaimedTask>("executor_inbox", "claim_fixture", "", &mut e);
    decode::<m::ExecutorDescription>("executors", "valid_fixture", "", &mut e);
    decode::<m::DiscoveredExecutor>("executors", "discovery_fixture", "", &mut e);
    decode::<m::CatalogModel>("models", "valid_fixture", "/models/0", &mut e);
    decode::<m::ProviderLane>(
        "models",
        "valid_provider_fixture",
        "/model_provider",
        &mut e,
    );
    decode::<m::Profile>("profiles", "alias_render_fixture", "", &mut e);
    decode::<m::NamedAgent>("profiles", "named_agents_fixture", "/agents/0", &mut e);
    decode::<m::MemoryDocument>("memory_documents", "valid_fixture", "/memory", &mut e);
    decode::<m::MemoryMatches>("memory_documents", "valid_grep_fixture", "", &mut e);
    decode::<m::PromptDocument>(
        "prompt_documents",
        "valid_fixture",
        "/prompt_document",
        &mut e,
    );
    decode::<m::KernelTool>("tools", "valid_listing_fixture", "/tools/0", &mut e);
    decode::<m::Schedule>("schedules", "valid_fixture", "/schedule", &mut e);
    decode::<m::ScheduleExecutionPage>("schedules", "valid_executions_fixture", "", &mut e);
    decode::<m::ConversationHistoryPage>("history", "read_fixture", "", &mut e);
    decode::<m::ConversationHistoryPage>("history", "execution_fixture", "", &mut e);
    decode::<m::ConversationSearchPage>("history", "search_fixture", "", &mut e);
    decode::<p::SessionGrant>("sessions", "valid_create_fixture", "", &mut e);
    decode::<p::Agent>("platform_agents", "valid_agent_fixture", "/agent", &mut e);
    decode::<p::AgentDetail>(
        "platform_agents",
        "valid_agent_detail_fixture",
        "/agent",
        &mut e,
    );
    decode::<p::AgentConfigurationSnapshot>(
        "platform_agents",
        "valid_agent_configuration_fixture",
        "",
        &mut e,
    );
    decode::<p::Runner>(
        "platform_runners",
        "valid_runners_fixture",
        "/runners/0",
        &mut e,
    );
    decode::<p::RunnerSnapshot>("platform_runners", "valid_runner_fixture", "", &mut e);
    decode::<p::PrivateRunner>(
        "platform_agents",
        "valid_private_runner_fixture",
        "/private_runner",
        &mut e,
    );
    decode::<p::ApiKeyGrant>(
        "platform_agents",
        "valid_member_key_grant_fixture",
        "",
        &mut e,
    );
    decode::<p::Budget>("platform_budgets", "valid_open_fixture", "/budget", &mut e);
    decode::<p::BudgetAdjustment>("platform_budgets", "unknown_entry_kind_fixture", "", &mut e);
    decode::<p::DeploymentState>(
        "platform_deployment",
        "valid_state_fixture",
        "/deployment",
        &mut e,
    );
    decode::<p::DeploymentUpgrade>(
        "platform_deployment",
        "unknown_status_fixture",
        "/upgrade",
        &mut e,
    );
    decode::<p::DeploymentLog>("platform_deployment", "valid_log_fixture", "/log", &mut e);
    decode::<p::UsageReport>("platform_usage", "valid_report_fixture", "/report", &mut e);
    assert!(e.is_empty(), "{}", e.join("\n"));
}
