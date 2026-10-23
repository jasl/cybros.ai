module E2E
  # Each group gets its own Nexus world; `e2e_serial` runs their flat union in one world.
  # Every default journey belongs to a group, and the manifest checks omissions and duplicates.
  #
  # Keep the per-test ceremony suites in ONE_PER_GROUP apart: device grants and steward
  # sign-ins share per-IP budgets inside a world. A shared_human writer also needs a world
  # without other shared_human readers, because persona and user-memory writes affect later
  # prompts regardless of randomized test order.
  #
  # WEIGHTS order heavier groups first when slots are limited. Rebalance when a group is more
  # than a fifth above the mean; only completed world runtimes count as measurements.
  module JourneyGroups
    HARNESS = %w[
      contract_fixtures
      kernel_tool_names
      manual_client_harness
      manual_openrouter_smoke
      bench_records_harness
      bench_client_harness
      result_dag_fixture_bench_harness
      task_bench_harness
      task_bench_sample_harness
      task_bench_read_class_harness
      task_bench_emulator_harness
      task_bench_door_harness
      attachment_line_bench_harness
      nexus_server_environment
      nexus_hosts_harness
      mcp_fixture_control_harness
      browser_actor_harness
      rho_webui_browser_harness
      platform_http
      process_runner
      sdk_process
      executor_process
      mock_llm_directives
      mock_llm_app
      mock_llm_wire_contract
      tool_lowering_contract
      journey_groups
      group_run
      world_slots
      diagnostic_tasks_harness
      gallery_shapes
      exit_long_pump_harness
      cost_stop_harness
      failure_dump_harness
      evals_corpus
      evals_bench
      evals_expected
      evals_scorecard
      evals_refusals
      evals_ledger
      evals_records
      evals_artifacts
      evals_predicates
      evals_claims
      evals_coverage
      evals_queue_pass
      evals_report_line
      evals_world_log
      evals_sealed_request
      evals_salvage
      evals_member_plane
      evals_rescore
      evals_verifications
      evals_agents_on_rails
      evals_terminal_bench
      evals_docker
      harbor_acp
      kernel_rule_grammar
      rho_daemon_harness
      rho_telegram_harness
      telegram_client_harness
      install_lane_harness
      stack_installation_harness
      acp_fixture
      fs_port_server
    ].freeze

    GROUPS = {
      # Persona writer; its neighbours own their homes and do not read shared Human state.
      1 => %w[rho_conversation rho_conversation_tasks rho_conversation_environment compiled_bytes
        assembly_bytes skills named_agents rho_acp_agent web_fetch],
      # User-memory writer; steward-owned journeys keep its notes away from shared readers.
      2 => %w[workspace_dedication approval memory_scopes history_search rho_runner_mode delegate_compaction
        side_conversation mcp_tools local_mcp_selection rewind mcp_oauth],
      # Kernel/SDK contracts and installation. Installation prerequisites remain explicit.
      3 => %w[provider_override until inference_request_hosts inference_request_stream multi_environment
        streaming conversation_acl attachments rho_attachments install_container install_compose install_host
        provider_floor schedules rho_acp_symmetry rho_spawn result_delivery_fallback replay_quality],
      # Connection lifecycle and smoke journeys; no shared Human writer.
      4 => %w[rho_daemon inference_request_workloads device_connection rho_core_only
        inference_request_recovery inference_request_feed workspace_lifecycle workspace_removal group_chat
        processes progress rho_run model_management rho_setup capture_upload expiry],
      # Bot connection and exact-task controls, with operator relay workflows.
      5 => %w[rho_telegram_bots ask_inbox executor_relay rho_telegram_controls],
      # Group observation and external execution authority.
      6 => %w[rho_telegram_group rho_telegram_permissions],
      # Conversation files reopen TurnTest; keep the complete class in one world.
      7 => %w[executor_plane turn conversation_regeneration conversation_background conversation_result_dag
        conversation_lifecycle variants conversation_view_state codemode],
      # Telegram ingress, history, memory and steering.
      8 => %w[rho_telegram rho_telegram_history rho_telegram_memory rho_telegram_commands],
      # Workspace/destination ownership and Nexus MCP. Both MCP suites need the fixture server.
      9 => %w[rho_telegram_workspace nexus_mcp offline_agent],
      # Media and external protocol adapters; language drivers keep their package toolchains.
      10 => %w[rho_telegram_media rho_telegram_delivery sdk_languages standalone_sdk_agent rho_acp_client],
      # Background application work, memory review and active participation.
      11 => %w[rho_telegram_participation rho_memory_review rho_household rho_t3],
      # Browser onboarding, configuration and installed packages.
      12 => %w[application_login api_key_connection rho_webui rho_structured_questions rho_settings
        rho_packages],
    }.freeze

    # Scheduling estimates include bootstrap and teardown, but exclude time waiting for a slot.
    # They order the longer worlds first; every world retains the same configured deadline.
    # Split groups start with estimates from their completed constituent cases;
    # only a completed world can replace an estimate with a measured runtime.
    WEIGHTS = { 1 => 440, 2 => 560, 3 => 515, 4 => 470, 5 => 380, 6 => 415,
                7 => 440, 8 => 445, 9 => 500, 10 => 410, 11 => 540, 12 => 450 }.freeze

    REALTIME = %w[realtime_signaling].freeze

    ONE_PER_GROUP = %w[rho_conversation workspace_dedication executor_plane rho_daemon].freeze
    SHARED_HUMAN_WRITERS = %w[compiled_bytes memory_scopes].freeze
    # Test files that are neither harness tests nor mock journeys: the paid
    # live lanes, the paid probes, the manual smoke and the explicitly
    # supplied disposable installation stack and API load measurement. Everything
    # else must be listed; load measurement runs through its named opt-in task.
    NON_JOURNEY = [/\Alive_/, /_probe\z/, /\Amanual_/, /\Astack_installation\z/, /\Aagent_api_load\z/].freeze
    TEST_DIR = File.expand_path("../test", __dir__)

    module_function

    # The flat union, in group order — the serial task's list.
    def journeys
      GROUPS.values.flatten
    end

    def paths(files)
      files.map { |name| "test/#{name}_test.rb" }
    end

    # The groups, heaviest first.
    def spawn_order(weights: WEIGHTS)
      GROUPS.keys.sort_by { |key| [-weights.fetch(key), key] }
    end

    def validate!(harness: HARNESS, groups: GROUPS, test_dir: TEST_DIR, weights: WEIGHTS, optional: REALTIME)
      problems = violations(harness: harness, groups: groups, test_dir: test_dir, weights: weights, optional: optional)
      return if problems.empty?

      raise ArgumentError, "journey manifest: #{problems.join("; ")}"
    end

    # Every rule, as a sentence naming the file, so a refusal says what to
    # move rather than that something is wrong.
    def violations(harness: HARNESS, groups: GROUPS, test_dir: TEST_DIR, weights: WEIGHTS, optional: REALTIME)
      listed = harness + groups.values.flatten + optional
      [
        *missing_files(listed, test_dir),
        *duplicates(listed),
        *unlisted(listed, test_dir),
        *doubled_ceremony_files(groups),
        *writer_beside_reader(groups, test_dir),
        *unweighted(groups, weights),
      ]
    end

    def unweighted(groups, weights)
      return [] if groups.keys.sort == weights.keys.sort

      ["WEIGHTS names #{weights.keys.sort.inspect} but the groups are #{groups.keys.sort.inspect}"]
    end

    def missing_files(listed, test_dir)
      listed.reject { |name| File.file?(File.join(test_dir, "#{name}_test.rb")) }
        .map { |name| "#{name} is listed but test/#{name}_test.rb does not exist" }
    end

    def duplicates(listed)
      listed.tally.select { |_name, count| count > 1 }
        .map { |name, count| "#{name} is listed #{count} times" }
    end

    def unlisted(listed, test_dir)
      Dir.children(test_dir).sort
        .filter_map { |file| file.delete_suffix("_test.rb") if file.end_with?("_test.rb") }
        .reject { |name| listed.include?(name) || NON_JOURNEY.any? { |pattern| pattern.match?(name) } }
        .map { |name| "test/#{name}_test.rb is in no group and not a harness test" }
    end

    def doubled_ceremony_files(groups)
      groups.filter_map do |key, files|
        doubled = files & ONE_PER_GROUP
        "group #{key} holds #{doubled.join(" and ")}; one of #{ONE_PER_GROUP.join("/")} per group" if doubled.size > 1
      end
    end

    def writer_beside_reader(groups, test_dir)
      groups.flat_map do |key, files|
        writers = files & SHARED_HUMAN_WRITERS
        next [] if writers.empty?

        (files - SHARED_HUMAN_WRITERS).select { |name| shared_human_reader?(name, test_dir) }
          .map { |name| "group #{key} holds the shared_human writer #{writers.join("/")} beside the reader #{name}" }
      end
    end

    def shared_human_reader?(name, test_dir)
      path = File.join(test_dir, "#{name}_test.rb")
      File.file?(path) && File.read(path, encoding: Encoding::UTF_8).include?("shared_human")
    end
  end
end
