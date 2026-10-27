module E2E
  module JourneyGroups
    HARNESS = %w[contract_fixtures nexus_server_environment nexus_hosts_harness mcp_fixture_control_harness browser_actor_harness platform_http process_runner sdk_process mock_llm_directives mock_llm_app tool_lowering_contract group_run world_slots failure_dump_harness].freeze
    GROUPS = {
      1 => %w[compiled_bytes],
      2 => %w[delegate_compaction],
      3 => %w[inference_request_hosts inference_request_stream streaming attachments provider_floor schedules result_delivery_fallback replay_quality],
      4 => %w[inference_request_workloads device_connection inference_request_recovery inference_request_feed workspace_lifecycle workspace_removal],
      9 => %w[offline_agent],
      10 => %w[sdk_languages sdk_decisions standalone_sdk_agent],
      13 => %w[fake_executor],
    }.freeze
    # The split groups have no measured timing yet; retain numeric scheduling order.
    WEIGHTS = GROUPS.to_h { |key, _| [key, 1] }.freeze
    REALTIME = %w[].freeze
    DIAGNOSTICS = %w[agent_api_load].freeze
    ONE_PER_GROUP = %w[].freeze
    SHARED_HUMAN_WRITERS = %w[compiled_bytes].freeze
    TEST_DIR = File.expand_path("../test", __dir__)
  end
end

require_relative "../../support/journey_manifest"
