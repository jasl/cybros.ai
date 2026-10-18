{
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.fetch().await {
            errors.push(format!("conversations.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_list_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m.conversations(&Default::default()).await {
            errors.push(format!("conversations.valid_list_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_turns_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.turns().list(&Default::default()).await {
            errors.push(format!("conversations.valid_turns_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_variants_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.turns().turn("turn").unwrap().variants().await {
            errors.push(format!("conversations.valid_variants_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_inputs_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.inputs().list().await {
            errors.push(format!("conversations.valid_inputs_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_materialization_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c
            .inputs()
            .input("input")
            .unwrap()
            .materialization(&Default::default())
            .await
        {
            errors.push(format!(
                "conversations.valid_materialization_fixture: {error}"
            ));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_events_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.events(&Default::default()).await {
            errors.push(format!("conversations.valid_events_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_estimate_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.estimate_input(&Default::default()).await {
            errors.push(format!("conversations.valid_estimate_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_rendered_estimate_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.estimate_input(&Default::default()).await {
            errors.push(format!(
                "conversations.valid_rendered_estimate_fixture: {error}"
            ));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_request_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c
            .turns()
            .turn("turn")
            .unwrap()
            .variant("variant")
            .unwrap()
            .request()
            .await
        {
            errors.push(format!("conversations.valid_request_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("conversations", "valid_regeneration_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let c = m.workspace("id").unwrap().conversation("id").unwrap();
        if let Err(error) = c.regeneration_receipt(&Default::default()).await {
            errors.push(format!("conversations.valid_regeneration_fixture: {error}"));
        }
    }
}
