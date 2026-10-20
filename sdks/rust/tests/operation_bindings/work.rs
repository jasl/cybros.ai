{
    operation!("GET /agent_api/v1/run_candidates", "GET", "/agent_api/v1/run_candidates",
        member.work().run_candidates(&Default::default()));
    operation!("GET /agent_api/v1/runs", "GET", "/agent_api/v1/runs",
        member.work().runs(&Default::default()));
    operation!("GET /agent_api/v1/attention", "GET", "/agent_api/v1/attention",
        member.work().attention(&Default::default()));
    operation!("GET /agent_api/v1/work_report", "GET", "/agent_api/v1/work_report",
        member.work().report(&Default::default()));
}
