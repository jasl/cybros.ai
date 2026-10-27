{
    operation!("GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/links", "GET", "/agent_api/v1/workspaces/fixture/conversations/fixture/links", member.workspace("fixture").unwrap().conversation("fixture").unwrap().links().list(&Default::default()));
    operation!("POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/links", "POST", "/agent_api/v1/workspaces/fixture/conversations/fixture/links", member.workspace("fixture").unwrap().conversation("fixture").unwrap().links().create(&Default::default(), "operation-key"));
    operation!("GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/links/{public_id}", "GET", "/agent_api/v1/workspaces/fixture/conversations/fixture/links/fixture", member.workspace("fixture").unwrap().conversation("fixture").unwrap().links().link("fixture").unwrap().fetch());
    operation!("POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/links/{link_public_id}/closure", "POST", "/agent_api/v1/workspaces/fixture/conversations/fixture/links/fixture/closure", member.workspace("fixture").unwrap().conversation("fixture").unwrap().links().link("fixture").unwrap().close());
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/export",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/export",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .export()
    );
    operation!(
        "DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{public_id}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/inputs/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .inputs()
            .input("fixture")
            .unwrap()
            .delete()
    );
    operation!(
        "DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/store_entries/{public_id}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/store_entries/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .delete(1)
    );
    operation!(
        "DELETE /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}",
        "DELETE",
        "/agent_api/v1/workspaces/fixture/conversations/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .delete()
    );
    operation!(
        "GET /agent_api/v1/conversations",
        "GET",
        "/agent_api/v1/conversations",
        member.conversations(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations",
        member
            .workspace("fixture")
            .unwrap()
            .conversations()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/archived",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/archived",
        member
            .workspace("fixture")
            .unwrap()
            .conversations()
            .archived(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/children",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/children",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .children(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/events",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/events",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .events(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/history",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/history",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .history(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/inputs",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .inputs()
            .list()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{input_public_id}/materialization",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/inputs/fixture/materialization",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .inputs()
            .input("fixture")
            .unwrap()
            .materialization(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .memory()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/regeneration_receipt",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/regeneration_receipt",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .regeneration_receipt(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{public_id}",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{schedule_public_id}/executions",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture/executions",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .executions(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/store_entries",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/store_entries",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .store_entries()
            .list(&Default::default())
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/store_entries/{public_id}",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/store_entries/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}",
        "GET",
        "/agent_api/v1/workspaces/fixture/conversations/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "PATCH /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/{public_id}",
        "PATCH",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/inputs/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .inputs()
            .input("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "PATCH /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{public_id}",
        "PATCH",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "PATCH /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/store_entries/{public_id}",
        "PATCH",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/store_entries/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .store_entries()
            .entry("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "PATCH /agent_api/v1/workspaces/{workspace_public_id}/conversations/{public_id}",
        "PATCH",
        "/agent_api/v1/workspaces/fixture/conversations/fixture",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations",
        member
            .workspace("fixture")
            .unwrap()
            .conversations()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/archive",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/archive",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .archive()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/takeover",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/takeover",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .takeover()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/cancellation",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/cancellation",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .cancel()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/compaction",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/compaction",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .compact(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/context_estimate",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/context_estimate",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .estimate_input(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/forks",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/forks",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .fork(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/inputs",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .inputs()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/inputs/reorder",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/inputs/reorder",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .inputs()
            .reorder(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .memory()
            .write(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/delete",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory/delete",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .memory()
            .delete(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/edit",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory/edit",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .memory()
            .edit(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/grep",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory/grep",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .memory()
            .grep(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory/show",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory/show",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .memory()
            .read(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/memory_context",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/memory_context",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .set_memory_context(&Default::default())
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{schedule_public_id}/cancel",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture/cancel",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .cancel()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{schedule_public_id}/pause",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture/pause",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .pause()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{schedule_public_id}/resume",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture/resume",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .resume()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/schedules/{schedule_public_id}/run",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/schedules/fixture/run",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .schedules()
            .schedule("fixture")
            .unwrap()
            .run()
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/store_entries",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/store_entries",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .store_entries()
            .create(&Default::default(), "operation-key")
    );
    operation!(
        "POST /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/unarchive",
        "POST",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/unarchive",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .unarchive()
    );
    operation!(
        "PUT /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/access",
        "PUT",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/access",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .set_access(&Default::default())
    );
    operation!(
        "PUT /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/default_runner",
        "PUT",
        "/agent_api/v1/workspaces/fixture/conversations/fixture/default_runner",
        member
            .workspace("fixture")
            .unwrap()
            .conversation("fixture")
            .unwrap()
            .set_default_runner(&Default::default())
    );
}
