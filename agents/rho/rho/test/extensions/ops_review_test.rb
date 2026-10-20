require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsReviewTest < Minitest::Test
  include RhoTest::OpsHarness

  class Api < NexusDoubles::FakeAgentApi
    attr_accessor :details

    def run_response(method, path, credential, body = nil)
      key = path[%r{/tasks/([^/]+)\z}, 1]
      if method == :get && credential == NexusDoubles::MEMBER_TOKEN && details&.key?(key)
        respond(200, { "task" => details.fetch(key) })
      else
        super
      end
    end
  end

  def test_review_uses_recorded_turn_results_and_original_runners_without_live_git_calls
    first = document("old.txt", "2026-10-20T00:00:01.000000Z")
    latest = document("saved.txt", "2026-10-20T00:00:02.000000Z")
    api = review_api({ "later-submit" => first, "earlier-submit" => latest })
    api.set_default_runner("c-1", "new-runner")
    daemon = member_ready(boot, api)
    response = read_review(daemon)
    assert_equal "200", response.code, response.body
    reviews = JSON.parse(response.body).fetch("reviews")
    assert_equal ["saved.txt"], reviews.first.fetch("files").map { |file| file.fetch("path") }
    assert_equal "original-runner", reviews.first.fetch("runner")
    assert_equal "run-1", reviews.first.fetch("run")
    assert_empty api.run_creates, "reading history must not invoke a Runner or inspect Git"
    assert_equal "401", request(daemon, :get, "/conversations/review?public_id=c-1&turn=turn-1&variant=v-1").code

    changed = read_review(daemon, variant: "obsolete")
    assert_equal "409", changed.code
    assert_equal "stale_variant", JSON.parse(changed.body).dig("error", "code")
  end

  def test_a_later_empty_snapshot_removes_reverted_changes
    api = review_api({ "first" => document("before.txt", "2026-10-20T00:00:01Z"),
      "reverted" => document(nil, "2026-10-20T00:00:02Z") })
    daemon = member_ready(boot, api)
    response = read_review(daemon)
    assert_equal "200", response.code, response.body
    assert_empty JSON.parse(response.body).fetch("reviews")
  end

  def test_reply_cutoff_excludes_later_tasks_and_keeps_each_original_runner
    api = review_api({ "first" => document("first.txt", "2026-10-20T00:00:01Z"),
      "second" => document("second.txt", "2026-10-20T00:00:02Z"),
      "late" => document("later.txt", "2026-10-20T00:00:04Z") })
    trace = api.instance_variable_get(:@trace)
    trace["completed_at"] = "2026-10-20T00:00:05Z"
    trace["deliverable_task_key"] = "answer"
    trace.fetch("tasks").each do |task|
      task["completed_at"] = task.fetch("key") == "late" ? "2026-10-20T00:00:04Z" : "2026-10-20T00:00:02Z"
      task.fetch("target")["executor_public_id"] = "second-runner" if task.fetch("key") == "second"
    end
    trace.fetch("tasks") << { "key" => "answer", "kind" => "model_task", "lifetime" => "conversation",
      "wake" => "auto", "status" => "completed", "on_failure" => "halt", "visibility" => "visible",
      "created_at" => "2026-10-20T00:00:00Z", "completed_at" => "2026-10-20T00:00:03Z" }
    variant = api.instance_variable_get(:@turns).first.fetch("active_variant")
    variant.fetch("runner_effects").fetch("runners") << { "runner_executor_public_id" => "second-runner",
      "run_public_id" => "run-1", "task_key" => "second" }

    response = read_review(member_ready(boot, api))
    assert_equal "200", response.code, response.body
    reviews = JSON.parse(response.body).fetch("reviews")
    assert_equal ["first.txt", "second.txt"], reviews.flat_map { |review| review.fetch("files").map { |file| file.fetch("path") } }
    assert_equal ["original-runner", "second-runner"], reviews.map { |review| review.fetch("runner") }
  end

  def test_unrecorded_untouched_pruned_and_reference_turns_do_not_read_current_files
    ["unrecorded", "untouched", "pruned", "reference", "running"].each do |kind|
      api = review_api({ "one" => nil })
      row = api.instance_variable_get(:@turns).first
      case kind
      when "untouched" then row.fetch("active_variant")["runner_effects"] = { "status" => "untouched", "runners" => [] }
      when "pruned" then row.fetch("active_variant")["details_pruned_at"] = "2026-10-20T00:00:00Z"
      when "reference" then row["reference"] = true
      when "running" then row["status"] = "running"
      else nil
      end
      daemon = member_ready(boot(root: File.join(@root, kind)), api)
      response = read_review(daemon)
      assert_equal "200", response.code, response.body
      assert_empty JSON.parse(response.body).fetch("reviews")
      assert_empty api.run_creates
    end
  end

  def test_feedback_keeps_historical_turn_and_excerpt
    daemon = member_ready(boot, review_api({}))
    comment = { "runner" => "original-runner", "root" => "/project", "base" => "a" * 64,
      "path" => "file.rb", "side" => "left", "line" => 2, "excerpt" => "<script>old</script>",
      "turn" => "turn-1", "variant" => "v-1", "run" => "run-1", "text" => "Keep this behavior" }
    response = request(daemon, :post, "/conversations/review/feedback", token: bearer(daemon),
      body: { public_id: "c-1", comment: comment })
    assert_equal "200", response.code, response.body
    assert_equal comment, JSON.parse(JSON.parse(response.body).fetch("text").split("\n", 2).last)
  end

  private

    def document(path, at)
      { "root" => "/project", "base" => "a" * 64, "captured_at" => at, "truncated" => false,
        "files" => path ? [{ "path" => path, "status" => "M", "state" => "text", "patch" => "@@ -1 +1 @@\n-old\n+new\n" }] : [] }
    end

    def review_api(documents)
      turn = { "public_id" => "turn-1", "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "completed", "visibility" => "visible", "inherited" => false, "created_at" => "2026-10-20T00:00:00Z",
        "answering_user_public_id" => "0199-user", "active_variant" => { "public_id" => "v-1", "source" => "run",
          "status" => "completed", "active" => true, "run_public_id" => "run-1", "content" => "Done",
          "runner_effects" => { "status" => "touched", "runners" => [{ "runner_executor_public_id" => "original-runner",
            "run_public_id" => "run-1", "task_key" => "first" }] } } }
      tasks = documents.map do |key, _|
        { "key" => key, "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed",
          "tool_name" => "edit", "on_failure" => "absorb", "visibility" => "visible", "created_at" => "2026-10-20T00:00:00Z",
          "target" => { "kind" => "runner", "executor_public_id" => "original-runner" } }
      end
      Api.new(turns: [turn], trace: NexusDoubles::RUNNING_TRACE.merge("status" => "completed", "tasks" => tasks)).tap do |api|
        api.details = tasks.to_h { |task| [task.fetch("key"), task.merge("metadata" => { "rho.changes" => documents.fetch(task.fetch("key")) })] }
      end
    end

    def read_review(daemon, variant: "v-1")
      request(daemon, :get, "/conversations/review?public_id=c-1&turn=turn-1&variant=#{variant}", token: bearer(daemon))
    end
end
