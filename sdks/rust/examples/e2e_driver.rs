//! Cross-language integration driver. Test infrastructure supplies all credentials
//! through stdin; stdout contains only public facts and explicit protocol events.
use cybros_agent::{
    Client, Error, ExecutorClient, PlatformClient, Result,
    authoring::{Step, ToolStep},
    credentials::SecretString,
    events::{KernelFeed, Position},
    execution::InputExecution,
    oauth::{AgentClaims, ConnectionClaims, ConnectionMode, OAuthClient},
    transport::UploadBody,
    types::requests::*,
};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    sync::Arc,
    time::Duration,
};
fn emit(value: Value) {
    println!("{value}");
    std::io::stdout().flush().expect("stdout");
}
fn required(v: &Value, key: &str) -> Result<String> {
    v.get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or(Error::Configuration(
            "driver input omitted a required field",
        ))
}
#[tokio::main]
async fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("stdin");
    let result = match serde_json::from_str::<Value>(&input) {
        Ok(v) => run(v).await,
        Err(_) => Err(Error::Configuration("invalid driver input")),
    };
    match result {
        Ok(mut v) => {
            v["event"] = json!("result");
            emit(v);
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
async fn run(v: Value) -> Result<Value> {
    let action = required(&v, "action")?;
    let base = required(&v, "base_url")?;
    match action.as_str() {
        "executor_announce" => {
            let c = ExecutorClient::new(&base, required(&v, "credential")?)?;
            let reply=c.announce(&Announcement{services: ServiceAnnouncements { agent: cybros_agent::Field::Value(ServiceAnnouncement::default()), runner: cybros_agent::Field::Value(ServiceAnnouncement {tools:vec![AnnouncedTool{name:"sdk_echo".into(),effect_profile:EffectProfile{kind:EffectKind::ReadOnly,destructive:false,effect_scope:EffectScope::Closed,idempotency:Idempotency::Intrinsic,reconciliation:Reconciliation::None},input_schema:json!({"type":"object","properties":{"marker":{"type":"string"}},"required":["marker"]}).as_object().cloned().unwrap().into(),..Default::default()}],..Default::default()}), ..Default::default()} }).await?;
            Ok(json!({"executor_public_id":reply.body.executor.public_id}))
        }
        "member_decision" => member_decision(&base, &v).await,
        "member_prepare" => {
            let c = Client::new(&base, required(&v, "credential")?)?;
            let marker = required(&v, "marker")?;
            let runner = required(&v, "runner_public_id")?;
            let w = c
                .workspaces()
                .create(
                    &CreateWorkspace {
                        name: format!("Rust {marker}"),
                        ..Default::default()
                    },
                    &required(&v, "workspace_key")?,
                )
                .await?
                .body;
            let workspace = c.workspace(&w.public_id)?;
            let conversation = workspace
                .conversations()
                .create(
                    &CreateConversation {
                        title: format!("Rust {marker}").into(),
                        default_runner_executor_public_id: runner.clone().into(),
                        ..Default::default()
                    },
                    &required(&v, "conversation_key")?,
                )
                .await?
                .body;
            let input = workspace
                .conversation(&conversation.public_id)?
                .inputs()
                .create(
                    &CreateInput {
                        text: format!("!mock -- {marker}").into(),
                        kind: InputKind::DirectReply.into(),
                        model: ModelRequest {
                            model: "dev/mock-text".to_string().into(),
                            ..Default::default()
                        }
                        .into(),
                        agent_configuration: AgentConfigurationRequest {
                            runner_executor_public_ids: vec![runner.clone()].into(),
                            runner_tool_names: vec![].into(),
                            approval_mode: ApprovalMode::Bypass.into(),
                            ..Default::default()
                        }
                        .into(),
                        approval_mode: ApprovalMode::Bypass.into(),
                        steps: vec![Step::Tool {
                            tool: ToolStep {
                                name: "sdk_echo".into(),
                                input: json!({"marker":marker}).as_object().cloned().unwrap(),
                                key: Some("sdk_echo".into()),
                                route: Some(ToolRoute::Runner {
                                    runner_executor_public_id: Some(runner),
                                }),
                                ..Default::default()
                            },
                        }]
                        .into(),
                        ..Default::default()
                    },
                    &required(&v, "input_key")?,
                )
                .await?
                .body;
            Ok(
                json!({"workspace_public_id":w.public_id,"conversation_public_id":conversation.public_id,"input_public_id":input.public_id}),
            )
        }
        "executor_complete" => {
            let c = ExecutorClient::new(&base, required(&v, "credential")?)?;
            let run = required(&v, "run_public_id")?;
            let task = required(&v, "task_key")?;
            let marker = required(&v, "marker")?;
            let inbox = c.inbox(&PageQuery::default()).await?.body;
            if !inbox
                .iter()
                .any(|t| t.run_public_id == run && t.task_key == task)
            {
                return Err(Error::Protocol("expected executor task was absent"));
            }
            let context = c.inbox_task(&run, &task)?;
            let claimed = context.claim().await?.body;
            if !context
                .claim_status(claimed.claim.claim_token.expose())
                .await?
                .body
                .active
            {
                return Err(Error::Protocol("claim inactive"));
            }
            let mut upload = UploadBody::bytes("capture.txt", format!("capture:{marker}"));
            upload.content_type = "text/plain".into();
            let upload = c.upload(upload).await?.body;
            context.commit(&CommitTask{claim_token:claimed.claim.claim_token,content:json!([{"type":"text","text":format!("echo:{marker}")},{"type":"resource_link","uri":format!("nexus://uploads/{}",upload.public_id),"name":"capture.txt","mimeType":"text/plain"}]).into(),structured_content:json!({"marker":marker}).into(),outcome:Outcome::Completed.into(),is_error:false.into(),..Default::default()}).await?;
            Ok(json!({"run_public_id":run,"task_key":task,"upload_public_id":upload.public_id}))
        }
        "member_observe" | "member_follow" | "member_cancel" => observe(&v, &base, &action).await,
        "platform_smoke" => {
            let grant = PlatformClient::login(
                &base,
                &Login {
                    email: required(&v, "email")?,
                    password: SecretString::new(required(&v, "password")?),
                },
            )
            .await?
            .body;
            let client = PlatformClient::new(&base, grant.token.expose())?;
            let profile = client.profile().fetch().await?.body;
            let agent = client
                .agents()
                .create(&CreateAgent {
                    display_name: required(&v, "marker")?,
                })
                .await?
                .body;
            // A small page exercises traversal even without the other journeys' Agents.
            let mut query = PageQuery {
                limit: Some(1),
                order: Some(Order::Asc),
                ..Default::default()
            };
            loop {
                let listed = client.agents().list(&query).await?.body;
                if listed.items.iter().any(|a| a.public_id == agent.public_id) {
                    break;
                }
                query.after = Some(
                    listed
                        .next_after
                        .ok_or(Error::Protocol("created agent absent from list"))?,
                );
            }
            client.agents().agent(&agent.public_id)?.remove().await?;
            client.session().revoke().await?;
            Ok(
                json!({"human_public_id":profile.member.public_id,"agent_public_id":agent.public_id,"removed":true}),
            )
        }
        "application_login" => {
            let client = OAuthClient::application(&base, &base)?;
            let marker = required(&v, "marker")?;
            let claims = ConnectionClaims::Agent(AgentClaims {
                agent_identifier: required(&v, "agent_identifier")?,
                agent_display_name: marker.clone(),
                executor_display_name: marker,
            });
            let authorization = client
                .request_authorization(Some(&claims), ConnectionMode::Login)
                .await?;
            emit(
                json!({"event":"authorization","user_code":authorization.user_code,"verification_uri":authorization.verification_uri,"verification_uri_complete":authorization.verification_uri_complete}),
            );
            let grant = client.await_credentials(&authorization).await?;
            let platform = PlatformClient::new(
                &base,
                grant
                    .platform_access_token
                    .as_ref()
                    .ok_or(Error::Protocol("Human grant omitted Platform bearer"))?
                    .expose(),
            )?;
            let human = platform.profile().fetch().await?.body.member.public_id;
            let rotated = client.rotate(&grant.refresh_token).await?;
            let changed = rotated.refresh_token != grant.refresh_token;
            let token = rotated
                .platform_access_token
                .as_ref()
                .ok_or(Error::Protocol("rotation omitted Platform bearer"))?;
            let platform = PlatformClient::new(&base, token.expose())?;
            if platform.profile().fetch().await?.body.member.public_id != human {
                return Err(Error::Protocol("rotation changed Human"));
            }
            client.revoke(token).await?;
            let revoked = platform
                .profile()
                .fetch()
                .await
                .err()
                .is_some_and(|e| e.status() == Some(401));
            if !revoked {
                return Err(Error::Protocol("revoked bearer remained usable"));
            }
            Ok(
                json!({"human_public_id":human,"has_agent_credentials":grant.agent.is_some(),"has_runner_credentials":grant.runner.is_some(),"refresh_rotated":changed,"revoked":revoked}),
            )
        }
        _ => Err(Error::Configuration("unsupported driver action")),
    }
}
async fn observe(v: &Value, base: &str, action: &str) -> Result<Value> {
    let credential = required(v, "credential")?;
    let c = Client::new(base, credential.clone())?;
    let workspace = required(v, "workspace_public_id")?;
    let conversation = required(v, "conversation_public_id")?;
    let input = required(v, "input_public_id")?;
    let position: Position = v
        .get("position")
        .filter(|v| !v.is_null())
        .map(|v| serde_json::from_value(v.clone()))
        .transpose()
        .map_err(|_| Error::Configuration("invalid position"))?
        .unwrap_or_default();
    let conversation_context = c.workspace(&workspace)?.conversation(&conversation)?;
    let mut feed = KernelFeed::new(Arc::new(conversation_context.clone()), position.clone())?;
    let mut observer = InputExecution::new(&c, &workspace, &conversation, &input, position)?;
    let mut sequences = vec![];
    #[cfg(feature = "realtime")]
    let cable = cybros_agent::realtime::CableClient::member(base, credential)?;
    #[cfg(feature = "realtime")]
    let channel = cybros_agent::realtime::Channel::Conversation {
        workspace_id: workspace.clone(),
        conversation_id: conversation.clone(),
        items: cybros_agent::realtime::Items::Events,
    };
    #[cfg(feature = "realtime")]
    let mut subscription = if action == "member_follow" {
        let report = feed
            .consume(|e, _| {
                sequences.push(e.sequence);
                async { Ok(()) }
            })
            .await?;
        if report.retention_gap {
            return Err(Error::RetentionGap {
                recovery: json!({"watermark":report.watermark}),
            });
        }
        let sub = cable.subscribe(channel.clone()).await?;
        emit(json!({"event":"ready"}));
        Some(sub)
    } else {
        None
    };
    #[cfg(not(feature = "realtime"))]
    if action == "member_follow" {
        return Err(Error::Configuration(
            "member_follow requires realtime feature",
        ));
    }
    let mut canceled = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let report = feed
            .consume(|e, _| {
                sequences.push(e.sequence);
                async { Ok(()) }
            })
            .await?;
        // State recovery below is explicit; retained cursors always refer to actual events.
        let _retention_gap = report.retention_gap;
        if let Some(snapshot) = observer.recover().await?.cloned() {
            if action == "member_cancel"
                && !canceled
                && let Some(run) = &snapshot.execution.run_public_id
            {
                c.workspace(&workspace)?
                    .run(run)?
                    .stop(&RunControl { force: true })
                    .await?;
                canceled = true;
                continue;
            }
            if (snapshot.terminal() || action == "member_cancel")
                && matches!(
                    snapshot.run_status.as_deref(),
                    Some("completed" | "canceled")
                )
            {
                return Ok(
                    json!({"turn_public_id":snapshot.execution.turn_public_id,"variant_public_id":snapshot.execution.variant_public_id,"run_public_id":snapshot.execution.run_public_id,"status":snapshot.status,"run_status":snapshot.run_status,"final_text":snapshot.content,"position":feed.position(),"sequences":sequences}),
                );
            }
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(Error::ObservationTimeout {
                elapsed: Duration::from_secs(60),
            });
        }
        #[cfg(feature = "realtime")]
        if let Some(sub) = &mut subscription {
            match tokio::time::timeout(Duration::from_millis(100), sub.next()).await {
                Ok(Err(_)) | Ok(Ok(None)) => {
                    subscription = Some(cable.subscribe(channel.clone()).await?);
                    emit(json!({"event":"reconnected"}));
                }
                _ => {}
            }
            continue;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn member_decision(base: &str, v: &Value) -> Result<Value> {
    let client = Client::new(base, required(v, "credential")?)?;
    let workspace = client.workspace(&required(v, "workspace_public_id")?)?;
    let requests = workspace.inference_requests();
    let created = requests
        .create(
            &CreateInferenceRequest {
                workload: Workload::Decision,
                model: ModelRequest {
                    model: required(v, "model")?.into(),
                    ..Default::default()
                },
                input: v["decision_input"].clone(),
                configuration: serde_json::from_value::<cybros_agent::types::JsonObject>(
                    json!({"questions": v["questions"]}),
                )
                .expect("decision configuration")
                .into(),
                ..Default::default()
            },
            &required(v, "input_key")?,
        )
        .await?;
    let id = created.body.public_id;
    let request = requests.inference_request(&id)?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    loop {
        let row = request.fetch().await?.body;
        if let Some(result) = row.result {
            return Ok(json!({"create_status": created.status, "public_id": id,
                "fetched_public_id": row.public_id, "status": row.status,
                "result_status": result.status, "answers": result.answers,
                "usage": result.usage, "error": result.error}));
        }
        if tokio::time::Instant::now() >= deadline {
            return Err(Error::Protocol("decision did not finish before deadline"));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}
