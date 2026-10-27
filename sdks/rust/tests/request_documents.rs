use cybros_agent::types::{Field, requests::*};
use serde_json::{json, to_value};

#[test]
fn run_list_keeps_work_filters() {
    let request = RunListQuery {
        from: Some("2026-09-01T00:00:00Z".into()),
        to: Some("2026-10-01T00:00:00Z".into()),
        answering_user_public_id: Some("answerer".into()),
        agent_public_id: Some("agent".into()),
        executor_public_id: Some("runner".into()),
        kind: Some(RunKind::Conversation),
        ..Default::default()
    };
    assert_eq!(
        to_value(request).unwrap(),
        json!({
            "from": "2026-09-01T00:00:00Z", "to": "2026-10-01T00:00:00Z",
            "answering_user_public_id": "answerer", "kind": "conversation",
            "agent_public_id": "agent", "executor_public_id": "runner"
        })
    );
}

#[test]
fn configuration_keeps_prompt_documents_beside_the_declaration() {
    let request = DeclareConfiguration {
        configuration: AgentConfigurationRequest {
            tool_definitions: vec![ToolDeclaration::Function(FunctionDeclaration {
                r#type: FunctionType::Function,
                function: FunctionDefinition {
                    name: "lookup".into(),
                    parameters: json!({"type":"object", "properties":{"query":{"type":"string"}}})
                        .as_object()
                        .unwrap()
                        .clone()
                        .into(),
                    ..Default::default()
                },
                route: DeclarationRoute::Mcp {
                    connection_public_id: "connection-id".into(),
                    tool_name: "remote_lookup".into(),
                }
                .into(),
                ..Default::default()
            })]
            .into(),
            prompt_mechanism: PromptMechanism::Default.into(),
            approval_rules: vec![ApprovalRule {
                tool: "lookup".into(),
                verdict: ApprovalVerdict::Ask,
                r#match: "private*".to_owned().into(),
                path: "query".to_owned().into(),
                ..Default::default()
            }]
            .into(),
            ..Default::default()
        },
        prompt_documents: PromptDocumentsRequest {
            system_prompt: WritePromptDocument {
                content: "Help {{user}}.".into(),
                role: PromptRole::Developer.into(),
            }
            .into(),
            summarizer: Field::Null,
        }
        .into(),
    };
    assert_eq!(
        to_value(request).unwrap(),
        json!({
            "configuration": {
                "tool_definitions": [{"type":"function", "function": {
                    "name":"lookup", "parameters":{"type":"object", "properties":{"query":{"type":"string"}}}
                }, "route":{"kind":"mcp", "connection_public_id":"connection-id", "tool_name":"remote_lookup"}}],
                "prompt_mechanism":"default",
                "approval_rules":[{"tool":"lookup", "verdict":"ask", "path":"query", "match":"private*"}]
            },
            "prompt_documents":{"system_prompt":{"content":"Help {{user}}.", "role":"developer"}, "summarizer":null}
        })
    );
}

#[test]
fn model_intent_and_input_context_have_independent_vocabularies() {
    let intent = ModelSelection {
        source: SelectionSource::Explicit,
        model: "local/primary".into(),
        constraint: SelectionConstraint::Route,
        alternatives: vec!["local/backup".into()].into(),
    };
    assert_eq!(
        to_value(intent).unwrap(),
        json!({
            "source":"explicit", "model":"local/primary", "constraint":"route", "alternatives":["local/backup"]
        })
    );
    assert_eq!(to_value(ContextMode::Assembled).unwrap(), "assembled");
    assert_eq!(to_value(PromptMechanism::Assembly).unwrap(), "assembly");
    assert!(serde_json::from_value::<ContextMode>(json!("assembly")).is_err());
    assert!(
        serde_json::from_value::<SelectionConstraint>(json!("allow_provider_fallback")).is_err()
    );
}

#[test]
fn access_memory_and_messaging_name_their_own_subjects() {
    let access = SetAccess {
        default: AccessLevel::None,
        entries: vec![AccessEntry::Handle {
            handle: "@reader".into(),
            level: AccessLevel::Read,
        }],
    };
    assert_eq!(
        to_value(access).unwrap(),
        json!({"default":"none", "entries":[{"handle":"@reader", "level":"read"}]})
    );
    let binding = MemoryBinding {
        name: "group".into(),
        source: MemorySource::Scope {
            scope: MemoryScope::Conversation,
            conversation_public_id: Some("conversation-id".into()),
            speaker_public_id: None,
        },
        access: MemoryAccess::Read,
    };
    assert_eq!(
        to_value(binding).unwrap(),
        json!({"name":"group", "source":{"scope":"conversation", "conversation_public_id":"conversation-id"}, "access":"read"})
    );
    let messaging = MessagingAgent {
        agent_public_id: "recipient-id".into(),
        mode: MessageVisibility::Private,
        allowed_sender_public_ids: vec!["sender-id".into()],
    };
    assert_eq!(
        to_value(messaging).unwrap(),
        json!({"agent_public_id":"recipient-id", "mode":"private", "allowed_sender_public_ids":["sender-id"]})
    );
}

#[test]
fn history_keeps_timeline_and_execution_windows_separate() {
    let query = HistoryQuery {
        before_position: Some(32),
        include_execution: Some(true),
        execution_before: Some("opaque-execution-cursor".into()),
        execution_prefix: Some("turn-id".into()),
        ..Default::default()
    };
    assert_eq!(
        to_value(query).unwrap(),
        json!({"before_position":32, "include_execution":true,
        "execution_before":"opaque-execution-cursor", "execution_prefix":"turn-id"})
    );
}

#[test]
fn named_agents_and_routes_use_distinct_request_shapes() {
    let request = NamedAgentRequest {
        scope: NamedAgentScope::Steward,
        description: "Reviewer".into(),
        create_only: true.into(),
        ..Default::default()
    };
    assert_eq!(
        to_value(request).unwrap(),
        json!({"scope":"steward", "description":"Reviewer", "configuration":{}, "create_only":true})
    );
    assert_eq!(
        to_value(ToolRoute::Runner {
            runner_executor_public_id: None
        })
        .unwrap(),
        json!({"kind":"runner"})
    );
    assert_eq!(
        to_value(DeclarationRoute::Runner {
            runner_executor_public_id: "runner-id".into(),
            tool_name: "read".into()
        })
        .unwrap(),
        json!({"kind":"runner", "runner_executor_public_id":"runner-id", "tool_name":"read"})
    );
}

#[test]
fn conversation_cost_limit_keeps_omission_null_and_exact_decimal() {
    assert_eq!(to_value(CreateConversation::default()).unwrap(), json!({}));
    assert_eq!(
        to_value(UpdateConversation {
            lock_version: 2,
            ..Default::default()
        })
        .unwrap(),
        json!({"lock_version": 2})
    );
    for limit in [
        Field::Value("0.123456789012345678".to_string()),
        Field::Null,
    ] {
        let expected = match &limit {
            Field::Value(amount) => json!(amount),
            Field::Null => serde_json::Value::Null,
            Field::Unset => unreachable!(),
        };
        assert_eq!(
            to_value(CreateConversation {
                cost_limit: limit.clone(),
                ..Default::default()
            })
            .unwrap(),
            json!({"cost_limit": expected})
        );
        assert_eq!(
            to_value(UpdateConversation {
                lock_version: 2,
                cost_limit: limit,
                ..Default::default()
            })
            .unwrap(),
            json!({"lock_version": 2, "cost_limit": expected})
        );
    }
}

#[test]
fn conversation_cost_limit_response_preserves_precision_and_reached_state() {
    let document: serde_json::Value = serde_json::from_str(include_str!(
        "../../../contracts/nexus/v1/conversations.json"
    ))
    .unwrap();
    for limit in [Some("0.123456789012345678"), None] {
        let mut body = document["valid_fixture"]["conversation"].clone();
        body["cost_limit"] = json!(limit);
        body["cost_limit_reached"] = json!(limit.is_some());
        let conversation: cybros_agent::types::member::Conversation =
            serde_json::from_value(body).unwrap();
        assert_eq!(conversation.cost_limit.as_deref(), limit);
        assert_eq!(conversation.cost_limit_reached, limit.is_some());
    }
}

#[test]
fn decision_inference_request_serializes_the_public_workload_and_questions() {
    let configuration = json!({"questions": [{
        "name": "allowed", "type": "choice", "instructions": "Choose whether allowed",
        "choices": [{"value": true}, {"value": false}]
    }]});
    let request = CreateInferenceRequest {
        workload: Workload::Decision,
        model: ModelRequest {
            model: "fixture/decision".to_owned().into(),
            ..Default::default()
        },
        input: json!({"allowed": false}),
        configuration: Field::Value(configuration.as_object().unwrap().clone().into()),
        ..Default::default()
    };
    assert_eq!(
        to_value(request).unwrap(),
        json!({
            "workload": "decision", "model": {"model": "fixture/decision"},
            "input": {"allowed": false}, "configuration": configuration
        })
    );
}
