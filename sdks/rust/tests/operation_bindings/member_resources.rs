{
    operation!(
        "DELETE /agent_api/v1/profile/agents/{name}",
        "DELETE",
        "/agent_api/v1/profile/agents/fixture",
        member.profile().agents().agent("fixture").unwrap().delete()
    );
    operation!(
        "DELETE /agent_api/v1/profile/prompt_documents/{slot}",
        "DELETE",
        "/agent_api/v1/profile/prompt_documents/fixture",
        member
            .profile()
            .prompt_documents()
            .document("fixture")
            .unwrap()
            .delete()
    );
    operation!(
        "DELETE /agent_api/v1/profile/store_entries/{public_id}",
        "DELETE",
        "/agent_api/v1/profile/store_entries/fixture",
        member
            .profile()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .delete(1)
    );
    operation!(
        "DELETE /agent_api/v1/workspaces/{public_id}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture",
        member.workspace("fixture").unwrap().delete(1)
    );
    operation!(
        "DELETE /agent_api/v1/workspaces/{workspace_public_id}/prompt_documents/{slot}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture/prompt_documents/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .prompt_documents()
            .document("fixture")
            .unwrap()
            .delete()
    );
    operation!(
        "DELETE /agent_api/v1/workspaces/{workspace_public_id}/store_entries/{public_id}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture/store_entries/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .delete(1)
    );
    operation!(
        "GET /agent_api/v1/mcp_connections",
        "GET",
        "/agent_api/v1/mcp_connections",
        member.mcp_connections().list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/mcp_connections/{id}",
        "GET",
        "/agent_api/v1/mcp_connections/fixture",
        member
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .fetch(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/model_providers",
        "GET",
        "/agent_api/v1/model_providers",
        member.model_providers().list()
    );
    operation!(
        "GET /agent_api/v1/models",
        "GET",
        "/agent_api/v1/models",
        member.models().list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/profile",
        "GET",
        "/agent_api/v1/profile",
        member.profile().fetch()
    );
    operation!(
        "GET /agent_api/v1/profile/agents",
        "GET",
        "/agent_api/v1/profile/agents",
        member.profile().agents().list()
    );
    operation!(
        "GET /agent_api/v1/profile/agents/{agent_name}/memory",
        "GET",
        "/agent_api/v1/profile/agents/fixture/memory",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .memory()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/profile/memory",
        "GET",
        "/agent_api/v1/profile/memory",
        member.profile().memory().list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/profile/prompt_documents",
        "GET",
        "/agent_api/v1/profile/prompt_documents",
        member.profile().prompt_documents().list()
    );
    operation!(
        "GET /agent_api/v1/profile/prompt_documents/{slot}",
        "GET",
        "/agent_api/v1/profile/prompt_documents/fixture",
        member
            .profile()
            .prompt_documents()
            .document("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /agent_api/v1/profile/store_entries",
        "GET",
        "/agent_api/v1/profile/store_entries",
        member.profile().store_entries().list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/profile/store_entries/{public_id}",
        "GET",
        "/agent_api/v1/profile/store_entries/fixture",
        member
            .profile()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /agent_api/v1/tools",
        "GET",
        "/agent_api/v1/tools",
        member.tools().list()
    );
    operation!(
        "GET /agent_api/v1/uploads/{public_id}",
        "GET",
        "/agent_api/v1/uploads/fixture",
        member.uploads().upload("fixture").unwrap().fetch()
    );
    operation!(
        "GET /agent_api/v1/uploads/{upload_public_id}/bytes",
        "GET",
        "/agent_api/v1/uploads/fixture/bytes",
        member
            .uploads()
            .upload("fixture")
            .unwrap()
            .bytes(None, None)
    );
    operation!(
        "GET /agent_api/v1/uploads/{upload_public_id}/preview",
        "GET",
        "/agent_api/v1/uploads/fixture/preview",
        member.uploads().upload("fixture").unwrap().preview(None)
    );
    operation!(
        "GET /agent_api/v1/uploads/{upload_public_id}/thumbnail",
        "GET",
        "/agent_api/v1/uploads/fixture/thumbnail",
        member.uploads().upload("fixture").unwrap().thumbnail(None)
    );
    operation!(
        "GET /agent_api/v1/workspaces",
        "GET",
        "/agent_api/v1/workspaces",
        member.workspaces().list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{public_id}",
        "GET",
        "/agent_api/v1/workspaces/fixture",
        member.workspace("fixture").unwrap().fetch()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversation_search",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversation_search",
        member
            .workspace("fixture")
            .unwrap()
            .search_conversations(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/memory",
        "GET",
        "/agent_api/v1/workspaces/fixture/memory",
        member
            .workspace("fixture")
            .unwrap()
            .memory()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/messaging",
        "GET",
        "/agent_api/v1/workspaces/fixture/messaging",
        member.workspace("fixture").unwrap().messaging()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/principals",
        "GET",
        "/agent_api/v1/workspaces/fixture/principals",
        member.workspace("fixture").unwrap().principals()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/prompt_documents",
        "GET",
        "/agent_api/v1/workspaces/fixture/prompt_documents",
        member
            .workspace("fixture")
            .unwrap()
            .prompt_documents()
            .list()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/prompt_documents/{slot}",
        "GET",
        "/agent_api/v1/workspaces/fixture/prompt_documents/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .prompt_documents()
            .document("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/schedules",
        "GET",
        "/agent_api/v1/workspaces/fixture/schedules",
        member
            .workspace("fixture")
            .unwrap()
            .schedules(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/store_entries",
        "GET",
        "/agent_api/v1/workspaces/fixture/store_entries",
        member
            .workspace("fixture")
            .unwrap()
            .store_entries()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/store_entries/{public_id}",
        "GET",
        "/agent_api/v1/workspaces/fixture/store_entries/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "PATCH /agent_api/v1/profile/store_entries/{public_id}",
        "PATCH",
        "/agent_api/v1/profile/store_entries/fixture",
        member
            .profile()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "PATCH /agent_api/v1/workspaces/{public_id}",
        "PATCH",
        "/agent_api/v1/workspaces/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "PATCH /agent_api/v1/workspaces/{workspace_public_id}/store_entries/{public_id}",
        "PATCH",
        "/agent_api/v1/workspaces/fixture/store_entries/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/agents/{agent_name}/memory",
        "POST",
        "/agent_api/v1/profile/agents/fixture/memory",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .memory()
            .write(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/agents/{agent_name}/memory/delete",
        "POST",
        "/agent_api/v1/profile/agents/fixture/memory/delete",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .memory()
            .delete(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/agents/{agent_name}/memory/edit",
        "POST",
        "/agent_api/v1/profile/agents/fixture/memory/edit",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .memory()
            .edit(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/agents/{agent_name}/memory/grep",
        "POST",
        "/agent_api/v1/profile/agents/fixture/memory/grep",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .memory()
            .grep(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/agents/{agent_name}/memory/show",
        "POST",
        "/agent_api/v1/profile/agents/fixture/memory/show",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .memory()
            .read(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/ingress_speakers",
        "POST",
        "/agent_api/v1/profile/ingress_speakers",
        member
            .profile()
            .resolve_ingress_speaker(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/memory",
        "POST",
        "/agent_api/v1/profile/memory",
        member.profile().memory().write(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/memory/delete",
        "POST",
        "/agent_api/v1/profile/memory/delete",
        member.profile().memory().delete(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/memory/edit",
        "POST",
        "/agent_api/v1/profile/memory/edit",
        member.profile().memory().edit(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/memory/grep",
        "POST",
        "/agent_api/v1/profile/memory/grep",
        member.profile().memory().grep(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/memory/show",
        "POST",
        "/agent_api/v1/profile/memory/show",
        member.profile().memory().read(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/profile/store_entries",
        "POST",
        "/agent_api/v1/profile/store_entries",
        member
            .profile()
            .store_entries()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/tools/assembly",
        "POST",
        "/agent_api/v1/tools/assembly",
        member.tools().assemble(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/uploads",
        "POST",
        "/agent_api/v1/uploads",
        member
            .uploads()
            .create(UploadBody::bytes("capture.txt", "hello"))
    );
    operation!(
        "POST /agent_api/v1/workspaces",
        "POST",
        "/agent_api/v1/workspaces",
        member
            .workspaces()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/archival",
        "POST",
        "/agent_api/v1/workspaces/fixture/archival",
        member.workspace("fixture").unwrap().archive(1)
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/memory",
        "POST",
        "/agent_api/v1/workspaces/fixture/memory",
        member
            .workspace("fixture")
            .unwrap()
            .memory()
            .write(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/memory/delete",
        "POST",
        "/agent_api/v1/workspaces/fixture/memory/delete",
        member
            .workspace("fixture")
            .unwrap()
            .memory()
            .delete(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/memory/edit",
        "POST",
        "/agent_api/v1/workspaces/fixture/memory/edit",
        member
            .workspace("fixture")
            .unwrap()
            .memory()
            .edit(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/memory/grep",
        "POST",
        "/agent_api/v1/workspaces/fixture/memory/grep",
        member
            .workspace("fixture")
            .unwrap()
            .memory()
            .grep(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/memory/show",
        "POST",
        "/agent_api/v1/workspaces/fixture/memory/show",
        member
            .workspace("fixture")
            .unwrap()
            .memory()
            .read(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/ownership_transfer",
        "POST",
        "/agent_api/v1/workspaces/fixture/ownership_transfer",
        member
            .workspace("fixture")
            .unwrap()
            .transfer_ownership(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/restoration",
        "POST",
        "/agent_api/v1/workspaces/fixture/restoration",
        member.workspace("fixture").unwrap().restore(1)
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/store_entries",
        "POST",
        "/agent_api/v1/workspaces/fixture/store_entries",
        member
            .workspace("fixture")
            .unwrap()
            .store_entries()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "PUT /agent_api/v1/profile/agents/{name}",
        "PUT",
        "/agent_api/v1/profile/agents/fixture",
        member
            .profile()
            .agents()
            .agent("fixture")
            .unwrap()
            .declare(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/profile/configuration",
        "PUT",
        "/agent_api/v1/profile/configuration",
        member.profile().configure(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/profile/prompt_documents/{slot}",
        "PUT",
        "/agent_api/v1/profile/prompt_documents/fixture",
        member
            .profile()
            .prompt_documents()
            .document("fixture")
            .unwrap()
            .write(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/workspaces/{workspace_public_id}/access_mode",
        "PUT",
        "/agent_api/v1/workspaces/fixture/access_mode",
        member
            .workspace("fixture")
            .unwrap()
            .update_access_mode(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/workspaces/{workspace_public_id}/messaging",
        "PUT",
        "/agent_api/v1/workspaces/fixture/messaging",
        member
            .workspace("fixture")
            .unwrap()
            .set_messaging(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/workspaces/{workspace_public_id}/prompt_documents/{slot}",
        "PUT",
        "/agent_api/v1/workspaces/fixture/prompt_documents/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .prompt_documents()
            .document("fixture")
            .unwrap()
            .write(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/workspaces/{workspace_public_id}/tool_provider_overrides",
        "PUT",
        "/agent_api/v1/workspaces/fixture/tool_provider_overrides",
        member
            .workspace("fixture")
            .unwrap()
            .set_tool_provider_overrides(&Default::default())
    );
}
