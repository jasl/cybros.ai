require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsArtifactsTest < Minitest::Test
  include RhoTest::OpsHarness

  def test_explicit_publications_are_read_separately_from_history_and_downloadable
    api = artifact_api(turns: [turn("parent", "parent-v", "parent-run")])
    daemon = member_ready(boot, api)
    history = request(daemon, :get, "/conversations/turns?public_id=c-1", token: bearer(daemon))
    assert_equal "200", history.code, history.body
    assert_empty run_reads(api), "ordinary history must not scan run tasks"

    response = artifacts(daemon)
    assert_equal "200", response.code, response.body
    assert_equal [{ "public_id" => "report", "filename" => "report.pdf", "content_type" => "application/pdf", "byte_size" => 12 }],
      JSON.parse(response.body).fetch("published_artifacts")
    assert_equal ["parent-run"], run_reads(api)
    tasks = api.requests.filter_map { |path, _| path[%r{/tasks/([^/]+)\z}, 1] }
    assert_equal ["published"], tasks, "incidental and failed publications are not attachment candidates"
    download = request(daemon, :get, "/uploads/bytes?public_id=report", token: bearer(daemon))
    assert_equal "200", download.code
    assert_equal "report bytes", download.body
  end

  def test_callbacks_read_the_accepted_worker_variant_and_its_nested_result
    parent = turn("parent", "parent-v", nil, sources: [callback("worker", "accepted-v")])
    worker = turn("worker", "later-v", "later-run", sources: [callback("nested", "nested-v")])
    nested = turn("nested", "nested-v", "nested-run")
    deck = { "turn" => { "public_id" => "worker" }, "variants" => [variant("accepted-v", "accepted-run"), worker.fetch("active_variant")] }
    api = artifact_api(turns: [parent, worker, nested], variants: deck)
    daemon = member_ready(boot, api)

    response = artifacts(daemon)
    assert_equal "200", response.code, response.body
    assert_equal ["report"], JSON.parse(response.body).fetch("published_artifacts").map { |file| file.fetch("public_id") }
    assert_equal %w[accepted-run nested-run], run_reads(api)
    assert api.requests.any? { |path, _| path.end_with?("/turns/worker/variants") }
  end

  def test_missing_pruned_or_unfinished_callback_results_do_not_replace_the_parent_files
    sources = [callback("missing", "absent-v"), callback("pruned", "pruned-v"), callback("unfinished", "unfinished-v")]
    parent = turn("parent", "parent-v", "parent-run", sources: sources)
    pruned = turn("pruned", "pruned-v", "pruned-run")
    pruned.fetch("active_variant")["details_pruned_at"] = "2026-10-01T00:00:00Z"
    unfinished = turn("unfinished", "unfinished-v", "unfinished-run")
    unfinished.fetch("active_variant")["status"] = "running"
    api = artifact_api(turns: [parent, pruned, unfinished])
    daemon = member_ready(boot, api)

    response = artifacts(daemon)
    assert_equal "200", response.code, response.body
    assert_equal ["report"], JSON.parse(response.body).fetch("published_artifacts").map { |file| file.fetch("public_id") }
    assert_equal ["parent-run"], run_reads(api)
  end

  def test_artifacts_require_the_displayed_variant_and_refuse_unreadable_turns
    api = artifact_api(turns: [turn("parent", "parent-v", "parent-run")])
    daemon = member_ready(boot, api)
    ["public_id=c-1", "public_id=c-1&turn=parent", "turn=parent&variant=parent-v"].each do |query|
      response = request(daemon, :get, "/conversations/artifacts?#{query}", token: bearer(daemon))
      assert_equal "400", response.code
    end
    stale = artifacts(daemon, variant: "old-v")
    assert_equal "409", stale.code
    assert_equal "stale_variant", JSON.parse(stale.body).dig("error", "code")
    missing = artifacts(daemon, turn: "missing")
    assert_equal "404", missing.code
    unauthorized = request(daemon, :get, "/conversations/artifacts?public_id=c-1&turn=parent&variant=parent-v")
    assert_equal "401", unauthorized.code
    assert_empty run_reads(api)
  end

  def test_unfinished_reference_and_pruned_answers_have_no_published_artifacts
    rows = [turn("unfinished", "unfinished-v", "unfinished-run"), turn("reference", "reference-v", "reference-run"),
      turn("pruned", "pruned-v", "pruned-run"), turn("summary", "summary-v", "summary-run")]
    rows[0].fetch("active_variant")["status"] = "running"
    rows[1]["reference"] = true
    rows[2].fetch("active_variant")["details_pruned_at"] = "2026-10-01T00:00:00Z"
    rows[3]["kind"] = "compaction_summary"
    api = artifact_api(turns: rows)
    daemon = member_ready(boot, api)

    rows.each do |row|
      response = artifacts(daemon, turn: row.fetch("public_id"), variant: row.dig("active_variant", "public_id"))
      assert_equal "200", response.code, response.body
      assert_empty JSON.parse(response.body).fetch("published_artifacts")
    end
    assert_empty run_reads(api)
  end

  private

    def artifact_api(turns:, **options)
      task = { "key" => "published", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
        "tool_name" => "file_publish", "on_failure" => "halt", "visibility" => "visible", "created_at" => "2026-10-01T00:00:00Z" }
      trace = NexusDoubles::RUNNING_TRACE.merge("status" => "completed", "tasks" => [task,
        task.merge("key" => "incidental", "tool_name" => "bash"), task.merge("key" => "failed", "result" => { "is_error" => true })])
      capture = { "type" => "resource_link", "uri" => "nexus://uploads/report", "name" => "report.pdf", "mimeType" => "application/pdf", "size" => 12 }
      NexusDoubles::FakeAgentApi.new(turns: turns, trace: trace, task_detail: task.merge("content" => [capture, capture]),
        upload_bytes: { "report" => "report bytes" }, **options)
    end

    def turn(id, variant_id, run, sources: [])
      { "public_id" => id, "position" => 0, "kind" => "direct_reply", "role" => "assistant", "status" => "completed",
        "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-01T00:00:00Z", "answering_user_public_id" => "0199-user",
        "active_variant" => variant(variant_id, run), "callback_sources" => sources }
    end

    def variant(id, run)
      { "public_id" => id, "source" => "run", "status" => "completed", "active" => true, "run_public_id" => run, "content" => "Report ready" }
    end

    def callback(id, variant)
      { "input_public_id" => "callback-#{id}", "origin" => "child", "result" => { "conversation_public_id" => "c-#{id}",
        "input_public_id" => "input-#{id}", "turn_public_id" => id, "variant_public_id" => variant } }
    end

    def artifacts(daemon, turn: "parent", variant: "parent-v")
      request(daemon, :get, "/conversations/artifacts?public_id=c-1&turn=#{turn}&variant=#{variant}", token: bearer(daemon))
    end

    def run_reads(api) = api.requests.filter_map { |path, _| path[%r{/runs/([^/]+)\z}, 1] }
end
