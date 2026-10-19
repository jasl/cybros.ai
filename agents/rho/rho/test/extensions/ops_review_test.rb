require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsReviewTest < Minitest::Test
  include RhoTest::OpsHarness

  def test_review_reads_the_bound_runner_and_formats_original_feedback
    document = { "root" => "/remote/project", "base" => "a" * 40,
                 "files" => [{ "path" => "a.rb", "status" => "M" }], "truncated" => false }
    api = NexusDoubles::FakeAgentApi.new(task_detail: {
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
      "tool_name" => "git_review", "output" => "Git review", "structured_content" => document,
      "on_failure" => "propagate", "visibility" => "visible", "created_at" => "2026-09-13T00:00:00Z",
    })
    api.set_default_runner("c-1", "0199-remote")
    api.stock_store_entry("c-1", namespace: "rho.environment", key: "binding/0199-remote",
      value: { "root" => "/remote/project", "directories" => [], "anchor" => "c-1" })
    daemon = member_ready(boot, api, identity: RUNNER_IDENTITY)
    store.remember(Rho::Host::Conversation.new(public_id: "c-1"), workspace: "ws-original", runner: "0199-stale")
    response = request(daemon, :get, "/conversations/review?public_id=c-1", token: bearer(daemon))
    assert_equal "200", response.code, response.body
    assert_equal "0199-remote", JSON.parse(response.body).dig("review", "runner")
    tool = api.run_creates.last.dig("run", "steps", 0, "tool")
    assert_equal "git_review", tool["name"]
    assert_equal({ "root" => "/remote/project" }, tool["input"])
    assert_equal "0199-remote", tool.dig("route", "runner_executor_public_id")
    changed = request(daemon, :get, "/conversations/review?public_id=c-1&runner=old", token: bearer(daemon))
    assert_equal "409", changed.code
    assert_equal 1, api.run_creates.length
    assert api.requests.any? { |path, *| path == "/agent_api/v1/workspaces/ws-original/runs" }
    assert_equal "401", request(daemon, :get, "/conversations/review?public_id=c-1").code

    comment = { "runner" => "0199-remote", "root" => "/remote/project", "base" => "a" * 40,
                "path" => "a.rb", "side" => "left", "line" => 2, "excerpt" => "<script>old</script>",
                "fingerprint" => "original", "text" => "Keep this behavior" }
    response = request(daemon, :post, "/conversations/review/feedback", token: bearer(daemon),
      body: { public_id: "c-1", comment: comment })
    assert_equal "200", response.code, response.body
    text = JSON.parse(response.body).fetch("text")
    assert_equal comment, JSON.parse(text.split("\n", 2).last)
  end
end
