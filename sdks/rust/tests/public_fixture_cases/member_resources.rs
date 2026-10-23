{
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("profiles", "agent_api").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.profile().fetch().await {
            errors.push(format!("profiles.agent_api: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("profiles", "named_agents_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.profile().agents().list().await {
            errors.push(format!("profiles.named_agents_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("profiles", "valid_ingress_speaker_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m
            .profile()
            .resolve_ingress_speaker(&Default::default())
            .await
        {
            errors.push(format!("profiles.valid_ingress_speaker_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("workspaces", "valid_full_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.workspace("id").unwrap().fetch().await {
            errors.push(format!("workspaces.valid_full_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("workspaces", "valid_list_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.workspaces().list(&Default::default()).await {
            errors.push(format!("workspaces.valid_list_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("workspaces", "valid_messaging_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.workspace("id").unwrap().messaging().await {
            errors.push(format!("workspaces.valid_messaging_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("workspaces", "valid_principals_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.workspace("id").unwrap().principals().await {
            errors.push(format!("workspaces.valid_principals_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("store_entries", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m
            .profile()
            .store_entries()
            .entry("id")
            .unwrap()
            .fetch()
            .await
        {
            errors.push(format!("store_entries.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("store_entries", "valid_list_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.profile().store_entries().list(&Default::default()).await {
            errors.push(format!("store_entries.valid_list_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("memory_documents", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.memory_collections().collection("collection").unwrap().documents().read(&Default::default()).await {
            errors.push(format!("memory_documents.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("memory_documents", "valid_list_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.memory_collections().collection("collection").unwrap().documents().list().await {
            errors.push(format!("memory_documents.valid_list_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("memory_documents", "valid_grep_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.memory_collections().collection("collection").unwrap().documents().grep(&Default::default()).await {
            errors.push(format!("memory_documents.valid_grep_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("prompt_documents", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m
            .profile()
            .prompt_documents()
            .document("slot")
            .unwrap()
            .fetch()
            .await
        {
            errors.push(format!("prompt_documents.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("prompt_documents", "valid_list_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.profile().prompt_documents().list().await {
            errors.push(format!("prompt_documents.valid_list_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("history", "read_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.history(&Default::default()).await {
            errors.push(format!("history.read_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("history", "execution_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.history(&Default::default()).await {
            errors.push(format!("history.execution_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("history", "search_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m
            .workspace("id")
            .unwrap()
            .search_conversations(&Default::default())
            .await
        {
            errors.push(format!("history.search_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("schedules", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.schedules().schedule("id").unwrap().fetch().await {
            errors.push(format!("schedules.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("schedules", "valid_list_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.schedules().list(&Default::default()).await {
            errors.push(format!("schedules.valid_list_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("schedules", "valid_executions_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c
            .schedules()
            .schedule("id")
            .unwrap()
            .executions(&Default::default())
            .await
        {
            errors.push(format!("schedules.valid_executions_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("models", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.models().list(&Default::default()).await {
            errors.push(format!("models.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("models", "valid_providers_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.model_providers().list().await {
            errors.push(format!("models.valid_providers_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("tools", "valid_listing_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.tools().list().await {
            errors.push(format!("tools.valid_listing_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("tools", "valid_assembly_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.tools().assemble(&Default::default()).await {
            errors.push(format!("tools.valid_assembly_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executors", "valid_fixture").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e.executor().await {
            errors.push(format!("executors.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("uploads", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.uploads().upload("id").unwrap().fetch().await {
            errors.push(format!("uploads.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("mcp_connections", "member_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.mcp_connections().connection("id").unwrap().fetch(&Default::default()).await {
            errors.push(format!("mcp_connections.member_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("mcp_connections", "owner_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.mcp_connections().connection("id").unwrap().fetch().await {
            errors.push(format!("mcp_connections.owner_fixture: {error}"));
        }
    }
}
