{
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("inference_requests", "valid_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m
            .workspace("id")
            .unwrap()
            .inference_requests()
            .inference_request("id")
            .unwrap()
            .fetch()
            .await
        {
            errors.push(format!("inference_requests.valid_fixture: {error}"));
        }
    }
    {
        let server = Server::script(vec![Reply::json(
            200,
            fixture("inference_requests", "valid_events_fixture").to_string(),
        )])
        .await;
        let m = Client::new(&server.url, "member").unwrap();
        if let Err(error) = m
            .workspace("id")
            .unwrap()
            .inference_requests()
            .inference_request("id")
            .unwrap()
            .events(&Default::default())
            .await
        {
            errors.push(format!("inference_requests.valid_events_fixture: {error}"));
        }
    }
}
