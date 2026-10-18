//! Submit one input. The caller supplies the operation key and owns observation.
use cybros_agent::types::requests::{CreateInput, InputKind, ModelRequest};
use cybros_agent::{Client, Result};

pub async fn submit(
    base_url: &str,
    member_credential: &str,
    workspace_id: &str,
    conversation_id: &str,
    operation_key: &str,
) -> Result<String> {
    let client = Client::new(base_url, member_credential)?;
    let conversation = client
        .workspace(workspace_id)?
        .conversation(conversation_id)?;
    let response = conversation
        .inputs()
        .create(
            &CreateInput {
                kind: InputKind::DirectReply.into(),
                text: "Hello".to_owned().into(),
                model: ModelRequest {
                    model: "local/example".to_owned().into(),
                    ..Default::default()
                }
                .into(),
                ..Default::default()
            },
            operation_key,
        )
        .await?;
    Ok(response.body.public_id)
}

fn main() {}
