{
    operation!(
        "DELETE /agent_api/v1/workspaces/{workspace_public_id}/inference_requests/{public_id}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture/inference_requests/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .inference_request("fixture")
            .unwrap()
            .delete()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/inference_requests",
        "GET",
        "/agent_api/v1/workspaces/fixture/inference_requests",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/inference_requests/{inference_request_public_id}/events",
        "GET",
        "/agent_api/v1/workspaces/fixture/inference_requests/fixture/events",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .inference_request("fixture")
            .unwrap()
            .events(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/inference_requests/{inference_request_public_id}/files/{index}",
        "GET",
        "/agent_api/v1/workspaces/fixture/inference_requests/fixture/files/0",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .inference_request("fixture")
            .unwrap()
            .download(0)
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/inference_requests/{public_id}",
        "GET",
        "/agent_api/v1/workspaces/fixture/inference_requests/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .inference_request("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/inference_requests",
        "POST",
        "/agent_api/v1/workspaces/fixture/inference_requests",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/inference_requests/input_estimate",
        "POST",
        "/agent_api/v1/workspaces/fixture/inference_requests/input_estimate",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .estimate_input(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/inference_requests/{inference_request_public_id}/cancellation",
        "POST",
        "/agent_api/v1/workspaces/fixture/inference_requests/fixture/cancellation",
        member
            .workspace("fixture")
            .unwrap()
            .inference_requests()
            .inference_request("fixture")
            .unwrap()
            .cancel()
    );
}
