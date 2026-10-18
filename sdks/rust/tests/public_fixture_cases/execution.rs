{
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("runs", "valid_request_run_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let r = m.workspace("id").unwrap().run("id").unwrap();
        if let Err(error) = r.fetch().await {
            errors.push(format!("runs.valid_request_run_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("runs", "valid_task_detail_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let r = m.workspace("id").unwrap().run("id").unwrap();
        if let Err(error) = r.task("task").unwrap().fetch().await {
            errors.push(format!("runs.valid_task_detail_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("runs", "valid_graph_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let r = m.workspace("id").unwrap().run("id").unwrap();
        if let Err(error) = r.graph().await {
            errors.push(format!("runs.valid_graph_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("runs", "valid_phases_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let r = m.workspace("id").unwrap().run("id").unwrap();
        if let Err(error) = r.phases().await {
            errors.push(format!("runs.valid_phases_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("runs", "valid_thread_page_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        let r = m.workspace("id").unwrap().run("id").unwrap();
        if let Err(error) = r.transcript(&Default::default()).await {
            errors.push(format!("runs.valid_thread_page_fixture: {error}"));
        }
    }
}
