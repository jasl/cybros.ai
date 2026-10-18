{
    operation!(
        "GET /api/v1/agents/{agent_id}/configuration",
        "GET", "/api/v1/agents/fixture/configuration",
        platform.agents().agent("fixture").unwrap().configuration()
    );
    operation!(
        "GET /api/v1/runners", "GET", "/api/v1/runners",
        platform.runners().list(&Default::default())
    );
    operation!(
        "GET /api/v1/runners/{id}", "GET", "/api/v1/runners/fixture",
        platform.runners().runner("fixture").unwrap().fetch()
    );
    operation!(
        "DELETE /api/v1/admin/model_providers/{model_provider_id}/api_key",
        "DELETE",
        "/api/v1/admin/model_providers/fixture/api_key",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .remove_api_key()
    );
    operation!(
        "DELETE /api/v1/admin/model_providers/{model_provider_id}/authorization",
        "DELETE",
        "/api/v1/admin/model_providers/fixture/authorization",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .authorization()
            .clear()
    );
    operation!(
        "DELETE /api/v1/admin/model_providers/{model_provider_id}/definition",
        "DELETE",
        "/api/v1/admin/model_providers/fixture/definition",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .reset_definition(&Default::default())
    );
    operation!(
        "DELETE /api/v1/admin/model_providers/{model_provider_id}/model_definition",
        "DELETE",
        "/api/v1/admin/model_providers/fixture/model_definition",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .remove_model_definition(&Default::default())
    );
    operation!(
        "DELETE /api/v1/mcp_connections/{mcp_connection_id}/credential",
        "DELETE",
        "/api/v1/mcp_connections/fixture/credential",
        platform
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .clear_credential(&Default::default())
    );
    operation!(
        "DELETE /api/v1/persona",
        "DELETE",
        "/api/v1/persona",
        platform.persona().delete()
    );
    operation!(
        "DELETE /api/v1/session",
        "DELETE",
        "/api/v1/session",
        platform.session().revoke()
    );
    operation!(
        "GET /api/v1/admin/account/cost_unit",
        "GET",
        "/api/v1/admin/account/cost_unit",
        platform.cost_unit().fetch()
    );
    operation!(
        "GET /api/v1/admin/account/retention",
        "GET",
        "/api/v1/admin/account/retention",
        platform.retention().fetch()
    );
    operation!(
        "GET /api/v1/admin/deployment",
        "GET",
        "/api/v1/admin/deployment",
        platform.deployment().fetch()
    );
    operation!(
        "GET /api/v1/admin/deployment/upgrades/{id}",
        "GET",
        "/api/v1/admin/deployment/upgrades/fixture",
        platform.deployment().operation("fixture").unwrap().fetch()
    );
    operation!(
        "GET /api/v1/admin/deployment/upgrades/{upgrade_id}/log",
        "GET",
        "/api/v1/admin/deployment/upgrades/fixture/log",
        platform
            .deployment()
            .operation("fixture")
            .unwrap()
            .log(&Default::default())
    );
    operation!(
        "GET /api/v1/admin/deployment/upgrades/{upgrade_id}/stream",
        "GET",
        "/api/v1/admin/deployment/upgrades/fixture/stream",
        platform
            .deployment()
            .operation("fixture")
            .unwrap()
            .stream(&Default::default(), None)
    );
    operation!(
        "GET /api/v1/admin/model_providers",
        "GET",
        "/api/v1/admin/model_providers",
        platform.model_providers().list()
    );
    operation!(
        "GET /api/v1/admin/model_providers/{id}",
        "GET",
        "/api/v1/admin/model_providers/fixture",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /api/v1/admin/model_providers/{model_provider_id}/authorization",
        "GET",
        "/api/v1/admin/model_providers/fixture/authorization",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .authorization()
            .fetch()
    );
    operation!(
        "GET /api/v1/admin/model_providers/{model_provider_id}/authorization/sessions/{id}",
        "GET",
        "/api/v1/admin/model_providers/fixture/authorization/sessions/fixture",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .authorization()
            .session("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /api/v1/admin/model_usage/report",
        "GET",
        "/api/v1/admin/model_usage/report",
        platform.model_usage(&Default::default())
    );
    operation!(
        "GET /api/v1/admin/models",
        "GET",
        "/api/v1/admin/models",
        platform.models().list(&Default::default())
    );
    operation!(
        "GET /api/v1/agents",
        "GET",
        "/api/v1/agents",
        platform.agents().list(&Default::default())
    );
    operation!(
        "GET /api/v1/agents/{agent_id}/api_keys",
        "GET",
        "/api/v1/agents/fixture/api_keys",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .api_keys()
            .list(&Default::default())
    );
    operation!(
        "GET /api/v1/agents/{agent_id}/executor/api_keys",
        "GET",
        "/api/v1/agents/fixture/executor/api_keys",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .executor_api_keys()
            .list(&Default::default())
    );
    operation!(
        "GET /api/v1/agents/{agent_id}/private_runners",
        "GET",
        "/api/v1/agents/fixture/private_runners",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .private_runners()
            .list(&Default::default())
    );
    operation!(
        "GET /api/v1/agents/{agent_id}/private_runners/{id}",
        "GET",
        "/api/v1/agents/fixture/private_runners/fixture",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .private_runners()
            .runner("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /api/v1/agents/{agent_id}/private_runners/{private_runner_id}/api_keys",
        "GET",
        "/api/v1/agents/fixture/private_runners/fixture/api_keys",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .private_runners()
            .runner("fixture")
            .unwrap()
            .api_keys()
            .list(&Default::default())
    );
    operation!(
        "GET /api/v1/agents/{id}",
        "GET",
        "/api/v1/agents/fixture",
        platform.agents().agent("fixture").unwrap().fetch()
    );
    operation!(
        "GET /api/v1/mcp_connections",
        "GET",
        "/api/v1/mcp_connections",
        platform.mcp_connections().list(&Default::default())
    );
    operation!(
        "GET /api/v1/mcp_connections/{id}",
        "GET",
        "/api/v1/mcp_connections/fixture",
        platform
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .fetch()
    );
    operation!(
        "GET /api/v1/persona",
        "GET",
        "/api/v1/persona",
        platform.persona().read()
    );
    operation!(
        "GET /api/v1/profile",
        "GET",
        "/api/v1/profile",
        platform.profile().fetch()
    );
    operation!(
        "GET /api/v1/session",
        "GET",
        "/api/v1/session",
        platform.session().fetch()
    );
    operation!(
        "PATCH /api/v1/admin/account/retention",
        "PATCH",
        "/api/v1/admin/account/retention",
        platform.retention().update(&Default::default())
    );
    operation!(
        "PATCH /api/v1/admin/users/{user_public_id}/budgets/{public_id}",
        "PATCH",
        "/api/v1/admin/users/fixture/budgets/fixture",
        platform
            .budgets("fixture")
            .unwrap()
            .budget("fixture")
            .unwrap()
            .adjust(&Default::default(), "operation-key")
    );
    operation!(
        "PATCH /api/v1/mcp_connections/{id}",
        "PATCH",
        "/api/v1/mcp_connections/fixture",
        platform
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .update(&Default::default())
    );
    operation!(
        "POST /api/v1/admin/deployment/release_check",
        "POST",
        "/api/v1/admin/deployment/release_check",
        platform.deployment().check_release(&Default::default())
    );
    operation!(
        "POST /api/v1/admin/deployment/upgrades",
        "POST",
        "/api/v1/admin/deployment/upgrades",
        platform
            .deployment()
            .upgrade(&Default::default(), "operation-key")
    );
    operation!(
        "POST /api/v1/admin/model_providers/{model_provider_id}/authorization",
        "POST",
        "/api/v1/admin/model_providers/fixture/authorization",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .authorization()
            .start(&Default::default())
    );
    operation!(
        "POST /api/v1/admin/model_providers/{model_provider_id}/model_definition/reset",
        "POST",
        "/api/v1/admin/model_providers/fixture/model_definition/reset",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .reset_model_definition(&Default::default())
    );
    operation!(
        "POST /api/v1/admin/model_providers/{model_provider_id}/model_discovery",
        "POST",
        "/api/v1/admin/model_providers/fixture/model_discovery",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .discover_models(&Default::default())
    );
    operation!(
        "POST /api/v1/admin/model_providers/{model_provider_id}/model_test",
        "POST",
        "/api/v1/admin/model_providers/fixture/model_test",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .test_model(&Default::default())
    );
    operation!(
        "POST /api/v1/admin/users/{user_public_id}/budgets",
        "POST",
        "/api/v1/admin/users/fixture/budgets",
        platform
            .budgets("fixture")
            .unwrap()
            .open(&Default::default(), "operation-key")
    );
    operation!(
        "POST /api/v1/admin/users/{user_public_id}/budgets/{budget_public_id}/revocation",
        "POST",
        "/api/v1/admin/users/fixture/budgets/fixture/revocation",
        platform
            .budgets("fixture")
            .unwrap()
            .budget("fixture")
            .unwrap()
            .revoke(&Default::default(), "operation-key")
    );
    operation!(
        "POST /api/v1/agents",
        "POST",
        "/api/v1/agents",
        platform.agents().create(&Default::default())
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/api_keys",
        "POST",
        "/api/v1/agents/fixture/api_keys",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .api_keys()
            .issue(&Default::default())
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/api_keys/{api_key_id}/revocation",
        "POST",
        "/api/v1/agents/fixture/api_keys/fixture/revocation",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .api_keys()
            .key("fixture")
            .unwrap()
            .revoke()
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/connection_revocation",
        "POST",
        "/api/v1/agents/fixture/connection_revocation",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .revoke_connection()
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/executor/api_keys",
        "POST",
        "/api/v1/agents/fixture/executor/api_keys",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .executor_api_keys()
            .issue(&Default::default())
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/executor/api_keys/{api_key_id}/revocation",
        "POST",
        "/api/v1/agents/fixture/executor/api_keys/fixture/revocation",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .executor_api_keys()
            .key("fixture")
            .unwrap()
            .revoke()
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/private_runners",
        "POST",
        "/api/v1/agents/fixture/private_runners",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .private_runners()
            .create(&Default::default())
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/private_runners/{private_runner_id}/api_keys",
        "POST",
        "/api/v1/agents/fixture/private_runners/fixture/api_keys",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .private_runners()
            .runner("fixture")
            .unwrap()
            .api_keys()
            .issue(&Default::default())
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/private_runners/{private_runner_id}/api_keys/{api_key_id}/revocation",
        "POST",
        "/api/v1/agents/fixture/private_runners/fixture/api_keys/fixture/revocation",
        platform
            .agents()
            .agent("fixture")
            .unwrap()
            .private_runners()
            .runner("fixture")
            .unwrap()
            .api_keys()
            .key("fixture")
            .unwrap()
            .revoke()
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/removal",
        "POST",
        "/api/v1/agents/fixture/removal",
        platform.agents().agent("fixture").unwrap().remove()
    );
    operation!(
        "POST /api/v1/agents/{agent_id}/restoration",
        "POST",
        "/api/v1/agents/fixture/restoration",
        platform.agents().agent("fixture").unwrap().restore()
    );
    operation!(
        "POST /api/v1/mcp_connections",
        "POST",
        "/api/v1/mcp_connections",
        platform.mcp_connections().create(&Default::default())
    );
    operation!(
        "POST /api/v1/mcp_connections/{mcp_connection_id}/authorization",
        "POST",
        "/api/v1/mcp_connections/fixture/authorization",
        platform
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .start_authorization(&Default::default())
    );
    operation!(
        "POST /api/v1/mcp_connections/{mcp_connection_id}/catalog_refresh",
        "POST",
        "/api/v1/mcp_connections/fixture/catalog_refresh",
        platform
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .refresh_catalog(&Default::default())
    );
    operation!(
        "POST /api/v1/session",
        "POST",
        "/api/v1/session",
        PlatformClient::login(&base, &Default::default())
    );
    operation!(
        "PUT /api/v1/admin/account/cost_unit",
        "PUT",
        "/api/v1/admin/account/cost_unit",
        platform.cost_unit().configure(&Default::default())
    );
    operation!(
        "PUT /api/v1/admin/model_providers/{model_provider_id}/api_key",
        "PUT",
        "/api/v1/admin/model_providers/fixture/api_key",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .install_api_key(&Default::default())
    );
    operation!(
        "PUT /api/v1/admin/model_providers/{model_provider_id}/definition",
        "PUT",
        "/api/v1/admin/model_providers/fixture/definition",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .set_definition(&Default::default())
    );
    operation!(
        "PUT /api/v1/admin/model_providers/{model_provider_id}/lane",
        "PUT",
        "/api/v1/admin/model_providers/fixture/lane",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .set_lane(&Default::default())
    );
    operation!(
        "PUT /api/v1/admin/model_providers/{model_provider_id}/model_availability",
        "PUT",
        "/api/v1/admin/model_providers/fixture/model_availability",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .set_model_availability(&Default::default())
    );
    operation!(
        "PUT /api/v1/admin/model_providers/{model_provider_id}/model_definition",
        "PUT",
        "/api/v1/admin/model_providers/fixture/model_definition",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .set_model_definition(&Default::default())
    );
    operation!(
        "PUT /api/v1/admin/model_providers/{model_provider_id}/model_visibility",
        "PUT",
        "/api/v1/admin/model_providers/fixture/model_visibility",
        platform
            .model_providers()
            .provider("fixture")
            .unwrap()
            .set_model_visibility(&Default::default())
    );
    operation!(
        "PUT /api/v1/mcp_connections/{mcp_connection_id}/credential",
        "PUT",
        "/api/v1/mcp_connections/fixture/credential",
        platform
            .mcp_connections()
            .connection("fixture")
            .unwrap()
            .rotate_credential(&Default::default())
    );
    operation!(
        "PUT /api/v1/persona",
        "PUT",
        "/api/v1/persona",
        platform.persona().write(&Default::default())
    );
}
