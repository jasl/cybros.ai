{
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("sessions", "valid_show_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.session().fetch().await {
            errors.push(format!("sessions.valid_show_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_agents", "valid_agent_detail_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.agents().agent("id").unwrap().fetch().await {
            errors.push(format!("platform_agents.valid_agent_detail_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_agents", "valid_agent_configuration_fixture").to_string(),
        )]).await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.agents().agent("id").unwrap().configuration().await {
            errors.push(format!("platform_agents.valid_agent_configuration_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200, fixture("platform_runners", "valid_runners_fixture").to_string(),
        )]).await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.runners().list(&Default::default()).await {
            errors.push(format!("platform_runners.valid_runners_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200, fixture("platform_runners", "valid_runner_fixture").to_string(),
        )]).await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.runners().runner("id").unwrap().fetch().await {
            errors.push(format!("platform_runners.valid_runner_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_agents", "valid_agents_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.agents().list(&Default::default()).await {
            errors.push(format!("platform_agents.valid_agents_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_agents", "valid_member_keys_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p
            .agents()
            .agent("id")
            .unwrap()
            .api_keys()
            .list(&Default::default())
            .await
        {
            errors.push(format!(
                "platform_agents.valid_member_keys_fixture: {error}"
            ));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_agents", "valid_executor_key_grant_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p
            .agents()
            .agent("id")
            .unwrap()
            .executor_api_keys()
            .issue(&Default::default())
            .await
        {
            errors.push(format!(
                "platform_agents.valid_executor_key_grant_fixture: {error}"
            ));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_budgets", "valid_open_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p
            .budgets("user")
            .unwrap()
            .open(&Default::default(), "key")
            .await
        {
            errors.push(format!("platform_budgets.valid_open_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_budgets", "valid_adjust_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p
            .budgets("user")
            .unwrap()
            .budget("id")
            .unwrap()
            .adjust(&Default::default(), "key")
            .await
        {
            errors.push(format!("platform_budgets.valid_adjust_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_deployment", "valid_state_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.deployment().fetch().await {
            errors.push(format!("platform_deployment.valid_state_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_deployment", "valid_upgrade_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.deployment().operation("id").unwrap().fetch().await {
            errors.push(format!(
                "platform_deployment.valid_upgrade_fixture: {error}"
            ));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_deployment", "valid_log_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p
            .deployment()
            .operation("id")
            .unwrap()
            .log(&Default::default())
            .await
        {
            errors.push(format!("platform_deployment.valid_log_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("platform_usage", "valid_report_fixture").to_string(),
        )])
        .await;
        let p = PlatformClient::new(&server.url, "platform").unwrap();
        if let Err(error) = p.model_usage(&Default::default()).await {
            errors.push(format!("platform_usage.valid_report_fixture: {error}"));
        }
    }
}
