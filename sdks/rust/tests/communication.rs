mod support;
use cybros_agent::{Client, types::CreateConversationLink};
use serde_json::{Value, json};
use support::{Reply, Server};

fn assert_wire(actual: &Value, expected: &Value) {
    match expected {
        Value::Object(fields) => {
            for (key, value) in fields {
                assert_wire(&actual[key], value);
            }
        }
        Value::Array(items) => {
            assert_eq!(actual.as_array().unwrap().len(), items.len());
            for (a, e) in actual.as_array().unwrap().iter().zip(items) {
                assert_wire(a, e);
            }
        }
        _ => assert_eq!(actual, expected),
    }
}

#[tokio::test]
async fn shared_communication_cases_use_public_resources() {
    let pack: Value = serde_json::from_str(include_str!(
        "../../../contracts/nexus/v1/communication.json"
    ))
    .unwrap();
    for example in pack["cases"].as_array().unwrap() {
        let body = &example["body"];
        let mut reply = Reply::json(example["status"].as_u64().unwrap() as u16, body.to_string());
        for (key, value) in example["headers"].as_object().unwrap() {
            reply
                .headers
                .push((key.clone(), value.as_str().unwrap().into()));
        }
        let mut server = Server::script(vec![reply]).await;
        let client = Client::new(&server.url, "member").unwrap();
        let scope = client
            .workspace("workspace")
            .unwrap()
            .conversation("conversation")
            .unwrap();
        let link_id = pack["link_public_id"].as_str().unwrap();
        match example["operation"].as_str().unwrap() {
            "link_create" => {
                let input: CreateConversationLink =
                    serde_json::from_value(pack["link_request"].clone()).unwrap();
                let response = scope.links().create(&input, "communication-key").await;
                if example["status"] == 409 {
                    assert_eq!(response.unwrap_err().status(), Some(409));
                } else {
                    let response = response.unwrap();
                    assert_wire(&serde_json::to_value(response.body).unwrap(), &body["link"]);
                    assert_eq!(
                        response.replayed,
                        example["headers"]["Idempotency-Replayed"] == "true"
                    );
                }
                let request = server.next().await;
                assert_eq!(
                    serde_json::from_slice::<Value>(&request.body).unwrap(),
                    json!({"link": pack["link_request"]})
                );
                assert_eq!(request.headers["idempotency-key"], "communication-key");
            }
            "link_read" => assert_wire(
                &serde_json::to_value(
                    scope
                        .links()
                        .link(link_id)
                        .unwrap()
                        .fetch()
                        .await
                        .unwrap()
                        .body,
                )
                .unwrap(),
                &body["link"],
            ),
            "link_close" => {
                assert_wire(
                    &serde_json::to_value(
                        scope
                            .links()
                            .link(link_id)
                            .unwrap()
                            .close()
                            .await
                            .unwrap()
                            .body,
                    )
                    .unwrap(),
                    &body["link"],
                );
                assert_eq!(server.next().await.method, "POST");
            }
            "link_list" => assert_wire(
                &serde_json::to_value(scope.links().list(&Default::default()).await.unwrap().body)
                    .unwrap(),
                body,
            ),
            "inputs" => assert_wire(
                &serde_json::to_value(scope.inputs().list().await.unwrap().body.items).unwrap(),
                &body["inputs"],
            ),
            "turn" => assert_wire(
                &serde_json::to_value(
                    scope
                        .turns()
                        .turn("turn")
                        .unwrap()
                        .fetch(&Default::default())
                        .await
                        .unwrap()
                        .body,
                )
                .unwrap(),
                &body["turn"],
            ),
            "events" => assert_wire(
                &serde_json::to_value(scope.events(&Default::default()).await.unwrap().body.items)
                    .unwrap(),
                &body["events"],
            ),
            "task" => {
                let detail = client
                    .workspace("workspace")
                    .unwrap()
                    .run("original-run")
                    .unwrap()
                    .task("original-task")
                    .unwrap()
                    .fetch()
                    .await
                    .unwrap()
                    .body;
                let actual = serde_json::to_value(detail).unwrap();
                for key in ["structured_content", "status", "output"] {
                    assert_eq!(actual[key], body["task"][key], "{} {key}", example["name"]);
                }
            }
            operation => panic!("Unhandled communication operation {operation}"),
        }
    }
}
