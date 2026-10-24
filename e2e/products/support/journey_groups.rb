module E2E
  module JourneyGroups
    HARNESS = %w[mock_llm_wire_contract kernel_rule_grammar kernel_tool_names manual_client_harness manual_openrouter_smoke bench_records_harness bench_client_harness result_dag_fixture_bench_harness task_bench_harness task_bench_sample_harness task_bench_read_class_harness task_bench_emulator_harness task_bench_door_harness attachment_line_bench_harness rho_webui_browser_harness executor_process journey_groups diagnostic_tasks_harness gallery_shapes exit_long_pump_harness cost_stop_harness evals_corpus evals_bench evals_expected evals_scorecard evals_refusals evals_ledger evals_records evals_artifacts evals_predicates evals_claims evals_coverage evals_queue_pass evals_report_line evals_world_log evals_sealed_request evals_salvage evals_member_plane evals_rescore evals_verifications evals_agents_on_rails evals_terminal_bench evals_docker harbor_acp rho_daemon_harness rho_telegram_harness telegram_client_harness install_lane_harness stack_installation_harness acp_fixture fs_port_server].freeze
    GROUPS = {
      1 => %w[rho_conversation rho_conversation_tasks rho_conversation_environment assembly_bytes skills named_agents rho_acp_agent web_fetch],
      2 => %w[workspace_dedication approval memory_scopes history_search rho_application_environment side_conversation mcp_tools local_mcp_selection rewind mcp_oauth],
      3 => %w[provider_override until multi_environment conversation_acl rho_attachments install_container install_compose install_host rho_acp_symmetry rho_spawn],
      4 => %w[rho_daemon rho_core_only group_chat processes progress rho_run model_management rho_setup capture_upload expiry],
      5 => %w[rho_telegram_bots ask_inbox executor_relay rho_telegram_controls],
      6 => %w[rho_telegram_group rho_telegram_permissions],
      7 => %w[executor_plane turn conversation_regeneration conversation_background conversation_result_dag conversation_lifecycle variants conversation_view_state codemode],
      8 => %w[rho_telegram rho_telegram_history rho_telegram_memory rho_telegram_commands],
      9 => %w[rho_telegram_workspace nexus_mcp],
      10 => %w[rho_telegram_media rho_telegram_delivery rho_acp_client],
      11 => %w[rho_telegram_participation rho_memory_review rho_household rho_t3],
      12 => %w[application_login api_key_connection rho_webui rho_structured_questions rho_settings rho_packages],
    }.freeze
    # The split groups have no measured timing yet; retain numeric scheduling order.
    WEIGHTS = GROUPS.to_h { |key, _| [key, 1] }.freeze
    REALTIME = %w[realtime_signaling].freeze
    DIAGNOSTICS = %w[attachment_line_probe context_overflow_probe live_acp_agent live_acp_client live_approval live_browser live_cache_tier live_capture live_console_reads live_conversation live_debugging live_default_runner live_deferred_tools live_deliver_at live_exit_long live_exit_medium live_gallery live_grant live_guard_and_conventions live_human_in_the_loop live_intervention live_long_session live_mcp live_mcp_oauth live_memory_scopes live_named_agent live_processes live_repair live_result_dag live_rho_runner live_run live_side live_spawn live_streaming live_task_mail live_tool_discovery_smoke live_two_loops_browser live_until live_vision live_web_fetch manual_provider_smoke prompt_cache_probe stack_installation task_matrix_probe].freeze
    ONE_PER_GROUP = %w[rho_conversation workspace_dedication executor_plane rho_daemon].freeze
    SHARED_HUMAN_WRITERS = %w[memory_scopes].freeze
    TEST_DIR = File.expand_path("../test", __dir__)
  end
end

require_relative "../../support/journey_manifest"
