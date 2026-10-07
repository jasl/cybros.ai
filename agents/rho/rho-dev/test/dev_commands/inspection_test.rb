require "support/dev_commands"

class DevCommandsTest
  # A daemon that restarted follows nothing while the workspace is still
  # full of live runs, so the local list alone made a restart look like an
  # empty machine.
  def test_runs_can_ask_the_workspace_and_marks_what_is_not_followed
    announce(endpoint: routed_endpoint(
      "GET /runs?attention=any" => [[200, { "runs" => [
        { "public_id" => "al-9", "status" => "running",
          "attention" => { "reason" => "halt_failure" }, "followed" => false },
      ] }]]
    ))

    rows = ops(:runs, attention: "any")

    assert_equal ["al-9"], rows.map { |row| row["public_id"] }
    assert_match(/^al-9  running  ASKING: halt_failure  not followed$/, @out.string)
  end

  def test_a_server_listing_with_nothing_matching_says_which_list_was_empty
    announce(endpoint: routed_endpoint(
      "GET /runs?status=running" => [[200, { "runs" => [] }]]
    ))

    assert_empty ops(:runs, status: "running")
    assert_match(/\(this workspace holds no matching runs\)/, @out.string)
  end

  # `rho providers` (the provider admission floor): one line
  # per lane, the kernel's `unavailable_until` printed as sent, `—` when null.
  def test_providers_prints_the_lanes_with_the_providers_clock
    announce(endpoint: routed_endpoint(
      "GET /providers" => [[200, { "providers" => [
        { "id" => "openrouter", "credentials" => "api_key", "enabled" => true, "configured" => true,
          "reauthorization_required" => false, "models" => 12, "unavailable_until" => "2026-09-16T09:00:00Z" },
        { "id" => "dev", "credentials" => "none", "enabled" => false, "configured" => true,
          "reauthorization_required" => false, "models" => 2, "unavailable_until" => nil },
      ] }]]
    ))

    rows = ops(:providers)

    assert_equal %w[openrouter dev], rows.map { |row| row["id"] }
    assert_match(/^openrouter  api_key  enabled  configured  12 models  unavailable until 2026-09-16T09:00:00Z$/,
      @out.string)
    assert_match(/^dev  none  disabled  configured  2 models  —$/, @out.string)
  end

  def test_providers_relays_the_daemons_refusal
    announce(endpoint: routed_endpoint(
      "GET /providers" => [[503, { "error" => { "message" => "the member plane is not available" } }]]
    ))

    error = assert_raises(Rho::Error) { ops(:providers) }
    assert_match(/member plane is not available/, error.message)
  end

  def test_runs_shows_how_many_checks_a_gated_run_has_spent
    announce(endpoint: routed_endpoint(
      "GET /followers" => [[200, { "followers" => [
        { "public_id" => "al-9", "status" => "running",
          "until" => { "command" => "make test", "attempts" => 3, "checks" => [{ "attempt" => 1 }] } },
      ] }]]
    ))

    ops(:followers)

    assert_match(/^al-9  running  until 1\/3$/, @out.string)
  end

  # ---- rho adaptations ----

  # `rho adaptations [--model M]` (left the core with `do`/`say`/`stop`): the row
  # resolved from the FILES alone and its fields; the boot row beside it
  # when M's row differs; then the kernel's facts for M through the
  # daemon, `(no daemon)` without one.
  def test_adaptations_prints_the_resolved_row_its_fields_and_the_kernels_facts
    RhoTest::LocalRows.write(home.adaptations_path, "mock", models: ["mock-text"], tool_style: %w[claude codex],
      lead_hints: [{ "id" => "k6", "text" => "Do not wait for a detached call." }], summarizer_prompt: "Summarize by pointers.")
    RhoTest::LocalRows.write(home.adaptations_path, "plain", models: ["plain-text"])
    File.write(home.settings_path, JSON.generate("default_model" => "dev/mock-text"))

    choice = ops(:adaptations)
    assert_equal "model:             dev/mock-text", lines[0]
    assert_equal "row:               mock (local #{File.join(home.adaptations_path, "mock.yml")})", lines[1]
    assert_equal "models:            mock-text (matched mock-text)", lines[2]
    assert_equal "tool_style:        claude, codex", lines[3]
    assert_equal "tool_descriptions: 0", lines[4]
    assert_match(/^  recut:           Agent ← "`wait: true` means your next round WAITS for the task: /, lines[5])
    specs = CybrosAgent::ModelAdaptations::Styles.alias_specs(choice.row, presets: CybrosAgent::ModelAdaptations.load.presets)
    expected = specs.select { |spec| spec.key?("recut") }.map do |spec|
      "  recut:           #{spec.fetch("name")} ← #{spec.dig("recut", "anchor").lines.first.to_s.strip.inspect}"
    end
    refute_empty expected, "the claude preset carries at least one recut"
    assert_equal expected, lines.select { |line| line.start_with?("  recut:") }
    assert_equal "summarizer:        #{Digest::SHA256.hexdigest("Summarize by pointers.")[0, 12]} 22 B (row)", lines[5 + expected.length]
    assert_equal ["lead_hints:        1", "  hint:            k6", "facts:             (no daemon)"], lines[(6 + expected.length)..]

    reset_out
    ops(:adaptations, model: "dev/plain-text")
    assert_equal "row:               plain (local #{File.join(home.adaptations_path, "plain.yml")})", lines[1]
    assert_equal "boot row:          mock — spellings are the boot's", lines[-2]
    assert_includes lines, "summarizer:        kernel default"
    refute(lines.any? { |line| line.start_with?("  recut:") }, "the plain row re-cuts nothing")

    reset_out
    File.write(home.settings_path, JSON.generate("default_model" => "dev/mock-text", "adaptations" => "off"))
    ops(:adaptations)
    assert_equal ["model:             dev/mock-text", "row:               off", "facts:             (no daemon)"], lines

    File.write(home.settings_path, JSON.generate("default_model" => "dev/mock-text"))
    api = NexusDoubles::FakeAgentApi.new(models: [
      { "ref" => "dev/mock-text", "provider" => "dev", "workload" => "text_generation", "visible" => true, "available" => true,
        "capabilities" => { "tool_calls" => true }, "pricing" => { "state" => "priced" } },
    ])
    daemon = boot(api: api)
    cli.connect
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 while daemon.lineage.runner(:runner).nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    reset_out
    ops(:adaptations)
    assert_match(/^facts:             tool_calls true \(catalog\)$/, @out.string, @out.string)
    reset_out
    ops(:adaptations, model: "dev/nobody")
    assert_match(%r{^facts:             model unavailable or unknown \(GET /models lists no dev/nobody\)$}, @out.string, @out.string)
  end

  # A daemon that refuses the facts read prints its sentence on the line;
  # one that cannot be reached is the verb's failure, as for every read.
  def test_adaptations_prints_a_refused_facts_read_on_the_line
    File.write(home.settings_path, JSON.generate("default_model" => "dev/mock-text"))
    announce(endpoint: routed_endpoint(
      "GET /adaptations" => [[503, { "error" => { "code" => "kernel_unavailable", "message" => "no member plane" } }]]
    ))
    ops(:adaptations)
    assert_equal "facts:             unavailable (no member plane)", lines.last

    announce(endpoint: inference_request_endpoint)
    assert_raises(Rho::ConnectionError) { ops(:adaptations) }
  end
end
