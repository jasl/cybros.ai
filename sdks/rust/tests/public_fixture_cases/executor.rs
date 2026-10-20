{
    {
        let server = Server::script(vec![Reply::json(200, fixture("executor_inbox", "realtime_fixture").to_string())]).await;
        let executor = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = executor.inbox_task("run", "task").unwrap().realtime("claim").await {
            errors.push(format!("executor_inbox.realtime_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executor_inbox", "valid_fixture").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e.inbox(&Default::default()).await {
            errors.push(format!("executor_inbox.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executor_inbox", "claim_fixture").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e.inbox_task("run", "task").unwrap().claim().await {
            errors.push(format!("executor_inbox.claim_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executor_operations", "accepted_operation").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e
            .inbox_task("run", "task")
            .unwrap()
            .submit(&Default::default())
            .await
        {
            errors.push(format!("executor_operations.accepted_operation: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executor_operations", "refused_operation").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e
            .inbox_task("run", "task")
            .unwrap()
            .submit(&Default::default())
            .await
        {
            errors.push(format!("executor_operations.refused_operation: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executor_operations", "refused_observation").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e
            .inbox_task("run", "task")
            .unwrap()
            .observe(&Default::default())
            .await
        {
            errors.push(format!("executor_operations.refused_observation: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("executor_operations", "waiting_observation").to_string(),
        )])
        .await;
        let e = ExecutorClient::new(&server.url, "executor").unwrap();
        if let Err(error) = e
            .inbox_task("run", "task")
            .unwrap()
            .observe(&Default::default())
            .await
        {
            errors.push(format!("executor_operations.waiting_observation: {error}"));
        }
    }
}
