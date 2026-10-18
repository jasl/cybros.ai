{
    operation!("GET /agent_api/v1/profile/budgets", "GET", "/agent_api/v1/profile/budgets", member.profile().budgets().list(&Default::default()));
    operation!("GET /agent_api/v1/profile/budgets/{budget_public_id}/entries", "GET", "/agent_api/v1/profile/budgets/fixture/entries", member.profile().budgets().budget("fixture").unwrap().entries(&Default::default()));
    operation!("GET /agent_api/v1/profile/budgets/{public_id}", "GET", "/agent_api/v1/profile/budgets/fixture", member.profile().budgets().budget("fixture").unwrap().fetch());
    operation!("GET /agent_api/v1/schedules", "GET", "/agent_api/v1/schedules", member.schedules().list(&Default::default()));
    operation!("GET /agent_api/v1/work_analysis", "GET", "/agent_api/v1/work_analysis", member.work().analysis(&Default::default()));
    operation!("GET /agent_api/v1/workspaces/{workspace_public_id}/conversations/{conversation_public_id}/turns/{turn_public_id}/variants/{public_id}", "GET", "/agent_api/v1/workspaces/fixture/conversations/fixture/turns/fixture/variants/fixture", member.workspace("fixture").unwrap().conversation("fixture").unwrap().turns().turn("fixture").unwrap().variant("fixture").unwrap().fetch());
    operation!("GET /api/v1/admin/model_usage/analysis", "GET", "/api/v1/admin/model_usage/analysis", platform.model_usage_analysis(&Default::default()));
    operation!("GET /api/v1/admin/users/{user_public_id}/budgets", "GET", "/api/v1/admin/users/fixture/budgets", platform.budgets("fixture").unwrap().list(&Default::default()));
    operation!("GET /api/v1/admin/users/{user_public_id}/budgets/{budget_public_id}/entries", "GET", "/api/v1/admin/users/fixture/budgets/fixture/entries", platform.budgets("fixture").unwrap().budget("fixture").unwrap().entries(&Default::default()));
    operation!("GET /api/v1/admin/users/{user_public_id}/budgets/{public_id}", "GET", "/api/v1/admin/users/fixture/budgets/fixture", platform.budgets("fixture").unwrap().budget("fixture").unwrap().fetch());
    operation!("GET /api/v1/agents/{agent_id}/budgets", "GET", "/api/v1/agents/fixture/budgets", platform.agents().agent("fixture").unwrap().budgets().list(&Default::default()));
    operation!("GET /api/v1/agents/{agent_id}/budgets/{budget_public_id}/entries", "GET", "/api/v1/agents/fixture/budgets/fixture/entries", platform.agents().agent("fixture").unwrap().budgets().budget("fixture").unwrap().entries(&Default::default()));
    operation!("GET /api/v1/agents/{agent_id}/budgets/{public_id}", "GET", "/api/v1/agents/fixture/budgets/fixture", platform.agents().agent("fixture").unwrap().budgets().budget("fixture").unwrap().fetch());
    operation!("GET /api/v1/profile/budgets", "GET", "/api/v1/profile/budgets", platform.profile().budgets().list(&Default::default()));
    operation!("GET /api/v1/profile/budgets/{budget_public_id}/entries", "GET", "/api/v1/profile/budgets/fixture/entries", platform.profile().budgets().budget("fixture").unwrap().entries(&Default::default()));
    operation!("GET /api/v1/profile/budgets/{public_id}", "GET", "/api/v1/profile/budgets/fixture", platform.profile().budgets().budget("fixture").unwrap().fetch());
    operation!("PATCH /api/v1/agents/{agent_id}/budgets/{public_id}", "PATCH", "/api/v1/agents/fixture/budgets/fixture", platform.agents().agent("fixture").unwrap().budgets().budget("fixture").unwrap().adjust(&Default::default(), "key"));
    operation!("POST /api/v1/agents/{agent_id}/budgets", "POST", "/api/v1/agents/fixture/budgets", platform.agents().agent("fixture").unwrap().budgets().open(&Default::default(), "key"));
    operation!("POST /api/v1/agents/{agent_id}/budgets/{budget_public_id}/revocation", "POST", "/api/v1/agents/fixture/budgets/fixture/revocation", platform.agents().agent("fixture").unwrap().budgets().budget("fixture").unwrap().revoke(&Default::default(), "key"));
}
