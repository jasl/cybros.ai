require "test_helper"
require "open3"
require "support/tool_discovery_smoke"

class DiagnosticTasksHarnessTest < Minitest::Test
  def test_paid_batches_require_opt_in_before_starting_a_child
    %w[live_exit live_sweep[until] live_deferred_tools live_tool_discovery_smoke].each do |task|
      output, status = run_task(task, "E2E_LIVE" => nil)

      refute status.success?, task
      assert_includes output, "set E2E_LIVE=1", task
      refute_includes output, "unexpected child launch", task
    end
  end

  def test_paid_batches_refuse_ci_before_starting_a_child
    %w[live_exit live_sweep[until] live_deferred_tools live_tool_discovery_smoke].each do |task|
      output, status = run_task(task, "E2E_LIVE" => "1", "CI" => "true")

      refute status.success?, task
      assert_includes output, "local-development only", task
      refute_includes output, "unexpected child launch", task
    end
  end

  def test_explicit_opt_in_reaches_the_child_launcher_with_the_default_development_environment
    %w[live_exit live_sweep[until]].each do |task|
      output, status = run_task(task, "E2E_LIVE" => "1", "RAILS_ENV" => nil)

      refute status.success?, task
      assert_equal "unexpected child launch\n", output, task
    end
  end

  def test_deferred_tools_requires_its_provider_key_before_boot
    output, status = run_task("live_deferred_tools", "E2E_LIVE" => "1", "DEEPSEEK_API_KEY" => nil)

    refute status.success?
    assert_includes output, "DEEPSEEK_API_KEY is not set"
    refute_includes output, "unexpected child launch"
  end

  def test_discovery_smoke_requires_every_selected_provider_key_before_boot
    output, status = run_task("live_tool_discovery_smoke", "E2E_LIVE" => "1", "OPENROUTER_API_KEY" => nil)

    refute status.success?
    assert_includes output, "OPENROUTER_API_KEY is not set"
    refute_includes output, "unexpected child launch"
  end

  def test_discovery_control_removes_only_accessors_flags_and_the_discovery_paragraph
    smoke = E2E::ToolDiscoverySmoke
    definitions = [
      { "function" => { "name" => "tool_search" } },
      { "function" => { "name" => "tool_call" } },
      { "function" => { "name" => "read" }, "defer_loading" => true, "route" => { "kind" => "runner" } },
    ]
    documents = { "system_prompt" => { "content" => "#{smoke::DISCOVERY_PREFIX} Discover the target.\n\nKeep this guideline.", "role" => "system" },
                  "summarizer" => { "content" => "Keep this summarizer." } }

    assert_equal [definitions.last.except("defer_loading")], smoke.definitions_for("eager_direct", definitions)
    assert_equal definitions, smoke.definitions_for("deferred", definitions)
    assert_equal "Keep this guideline.", smoke.documents_for("eager_direct", documents).dig("system_prompt", "content")
    assert_equal "system", smoke.documents_for("eager_direct", documents).dig("system_prompt", "role")
    assert_equal documents.fetch("summarizer"), smoke.documents_for("eager_direct", documents).fetch("summarizer")
    assert_equal documents, smoke.documents_for("deferred", documents)
  end

  def test_discovery_call_count_keeps_repeated_provider_ids_in_distinct_rounds
    call = ->(name) { { "type" => "tool_call_item", "payload" => { "call_id" => "nx_call_0", "name" => name } } }
    inherited = call.call("old_read")
    search = call.call("tool_search")
    invoke = call.call("tool_call")
    requests = [
      { "entries" => [inherited] },
      { "entries" => [inherited, search] },
      { "entries" => [inherited, search, invoke] },
    ]

    assert_equal %w[tool_search tool_call], E2E::ToolDiscoverySmoke.model_calls(requests).map { |item| item.fetch("name") }
    assert_empty E2E::ToolDiscoverySmoke.model_calls([])
  end

  private

    def run_task(task, env)
      script = <<~RUBY
        require "rake"
        def system(*) = abort("unexpected child launch")
        Rake.application.run(ARGV)
      RUBY
      defaults = { "E2E_LIVE_MODEL" => "fixture/floor", "E2E_SWEEP_MODELS" => "fixture/floor",
                   "RAILS_ENV" => "development", "CI" => nil }
      Open3.capture2e(defaults.merge(env), Gem.ruby, "-I.", "-e", script, task,
        chdir: File.expand_path("..", __dir__))
    end
end
