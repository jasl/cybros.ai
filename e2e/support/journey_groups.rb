module E2E
  # Each group gets its own Nexus world; `e2e_serial` runs their flat union in one world.
  # Every journey belongs to a group, and the manifest checks omissions and duplicates.
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
      compose_bench_rows_harness
      compose_bench_pictures_harness
      compose_bench_lowering_harness
      compose_bench_buckets_harness
      compose_bench_probe_harness
      compose_bench_inline_harness
      compose_bench_executed_harness
      compose_bench_usable_harness
      compose_bench_endpoints_harness
      compose_bench_replay_harness
      compose_bench_delivery_harness
      compose_bench_refusals_harness
      compose_bench_heartbeat_harness
      compose_bench_worlds_harness
      compose_bench_rehearsal_harness
      manual_client_harness
      bench_spend_harness
      bench_records_harness
      bench_client_harness
      screen_definition_harness
      screen_stage0_harness
      screen_stage0_gates_harness
      screen_stems_harness
      screen_watch_rules_harness
      screen_launcher_harness
      screen_stamp_harness
      screen_smoke_harness
      screen_readout_harness
      screen_rehearsal_harness
      screen_stats_harness
      screen_analysis_harness
      screen_cells_harness
      screen_corpus_harness
      screen_door_reader_harness
      screen_counterfactual_harness
      result_dag_fixture_bench_harness
      task_bench_harness
      task_bench_sample_harness
      task_bench_read_class_harness
      task_bench_emulator_harness
      task_bench_door_harness
      attachment_line_bench_harness
      nexus_server_environment
      nexus_hosts_harness
      browser_actor_harness
      platform_http
      process_runner
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
      evals_predicates
      evals_door_kind_harness
      evals_usable
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
      install_lane_harness
      acp_fixture
      fs_port_server
    ].freeze

    GROUPS = {
      # The persona writer shares a world only with journeys that own their homes and do not read
      # shared_human state. Keep the per-test ceremony file separate from the other groups' ceremony
      # files.
      1 => %w[rho_conversation rho_conversation_tasks rho_conversation_environment compiled_bytes assembly_bytes skills named_agents rho_acp_client rho_acp_agent web_fetch],
      # The user-memory writer stays with steward-owned journeys so its notes cannot affect another
      # test's shared_human prompts.
      2 => %w[workspace_dedication approval memory_scopes memory_conditional_writes history_search rho_runner_mode delegate_compaction side_conversation
              mcp_tools rewind todo mcp_oauth],
      # Shared_human readers stay away from both writer groups. Install journeys use prebuilt
      # images; a missing prerequisite skips explicitly and never counts as a successful
      # installation check.
      3 => %w[provider_override until one_shot_hosts one_shot_stream handoff streaming conversation_acl
              attachments rho_attachments loop_timings
              install_container install_compose install_host provider_floor scheduled_input scheduled_jobs rho_acp_symmetry
              rho_spawn mail_fallback replay_quality],
      # Independent readers and privately provisioned lifecycle journeys fill this world without
      # introducing a shared_human writer.
      4 => %w[
        rho_daemon one_shot_workloads device_connection rho_core_only
        one_shot_recovery one_shot_turn one_shot_feed workspace_lifecycle workspace_removal group_chat processes
        progress rho_run model_management rho_setup capture_upload expiry
      ],
      # Telegram suites share only setup and helper methods, so neither world reruns the other.
      # Both provision their own rho homes and use the steward rather than shared_human memory.
      5 => %w[rho_telegram ask_inbox executor_relay],
      6 => %w[rho_telegram_group],
      # The conversation files reopen one test class and require its main file. Keep the whole
      # class together so moving its cases does not rerun the main file in another world.
      7 => %w[executor_plane rho_webui rho_settings conversation_turn conversation_regeneration conversation_background
              conversation_result_dag conversation_lifecycle conversation_variants conversation_view_state],
    }.freeze

    # Scheduling estimates include bootstrap and teardown, but exclude time waiting for a slot.
    # They order the longer worlds first; every world retains the same configured deadline.
    WEIGHTS = { 1 => 783, 2 => 719, 3 => 702, 4 => 728, 5 => 726, 6 => 800, 7 => 654 }.freeze

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

    def validate!(harness: HARNESS, groups: GROUPS, test_dir: TEST_DIR, weights: WEIGHTS)
      problems = violations(harness: harness, groups: groups, test_dir: test_dir, weights: weights)
      return if problems.empty?

      raise ArgumentError, "journey manifest: #{problems.join("; ")}"
    end

    # Every rule, as a sentence naming the file, so a refusal says what to
    # move rather than that something is wrong.
    def violations(harness: HARNESS, groups: GROUPS, test_dir: TEST_DIR, weights: WEIGHTS)
      listed = harness + groups.values.flatten
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
