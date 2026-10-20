{
    operation!("GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/realtime", "GET",
        "/agent_api/v1/executor/inbox/fixture/fixture/realtime", executor.inbox_task("fixture", "fixture").unwrap().realtime("claim"));
    operation!("PUT /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/realtime", "PUT",
        "/agent_api/v1/executor/inbox/fixture/fixture/realtime", executor.inbox_task("fixture", "fixture").unwrap().offer_realtime("claim", &cybros_agent::types::requests::RealtimeOffer { connection_id: "connection".into(), sdp: "offer".into(), previous_connection_id: None }));
    operation!(
        "GET /agent_api/v1/executor",
        "GET",
        "/agent_api/v1/executor",
        executor.executor()
    );
    operation!(
        "GET /agent_api/v1/executor/inbox",
        "GET",
        "/agent_api/v1/executor/inbox",
        executor.inbox(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{attachment_upload_public_id}/bytes",
        "GET",
        "/agent_api/v1/executor/inbox/fixture/fixture/attachments/fixture/bytes",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .attachment_bytes("fixture", "claim-token", None)
    );
    operation!(
        "GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{upload_public_id}",
        "GET",
        "/agent_api/v1/executor/inbox/fixture/fixture/attachments/fixture",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .attachment("fixture", "claim-token")
    );
    operation!(
        "GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim",
        "GET",
        "/agent_api/v1/executor/inbox/fixture/fixture/claim",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .claim_status("claim-token")
    );
    operation!(
        "GET /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/operations",
        "GET",
        "/agent_api/v1/executor/inbox/fixture/fixture/operations",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .operations("claim-token", &Default::default())
    );
    operation!(
        "GET /agent_api/v1/executors",
        "GET",
        "/agent_api/v1/executors",
        member.executors().list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/executors/{public_id}",
        "GET",
        "/agent_api/v1/executors/fixture",
        member.executors().executor("fixture").unwrap().fetch()
    );
    operation!(
        "POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/claim",
        "POST",
        "/agent_api/v1/executor/inbox/fixture/fixture/claim",
        executor.inbox_task("fixture", "fixture").unwrap().claim()
    );
    operation!(
        "POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/commit",
        "POST",
        "/agent_api/v1/executor/inbox/fixture/fixture/commit",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .commit(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/extend",
        "POST",
        "/agent_api/v1/executor/inbox/fixture/fixture/extend",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .extend(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/observation",
        "POST",
        "/agent_api/v1/executor/inbox/fixture/fixture/observation",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .observe(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/executor/inbox/{run_public_id}/{task_key}/operations",
        "POST",
        "/agent_api/v1/executor/inbox/fixture/fixture/operations",
        executor
            .inbox_task("fixture", "fixture")
            .unwrap()
            .submit(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/executor/progress",
        "POST",
        "/agent_api/v1/executor/progress",
        executor.report_progress(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/executor/uploads",
        "POST",
        "/agent_api/v1/executor/uploads",
        executor.upload(UploadBody::bytes("capture.txt", "hello"))
    );
    operation!(
        "PUT /agent_api/v1/executor/announcement",
        "PUT",
        "/agent_api/v1/executor/announcement",
        executor.announce(&Default::default())
    );
}
