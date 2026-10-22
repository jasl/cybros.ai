require "test_helper"
require "cybros_agent/test_support/fake_realtime"

class DaemonApplicationExecutorTest < Minitest::Test
  include RhoTest::DaemonHarness

  def test_full_mode_announces_both_roles_and_runs_environment_work_on_one_application_inbox
    root = File.join(@root, "project")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "marker.txt"), "application environment")
    task = {
      "kind" => "tool_call", "run_public_id" => "run-local", "task_key" => "read-local",
      "conversation_public_id" => nil, "parent_public_id" => nil,
      "tool_name" => "read", "tool_input" => { "path" => "marker.txt" }, "tool_call_id" => "call-local",
      "executor_context" => { "rho.environment" => { "root" => root, "directories" => [] } },
      "started_at" => "2026-10-21T00:00:00Z", "deadline_at" => nil, "claimed" => false,
      "addressed_to" => { "role" => "runner", "executor_public_id" => "0199-executor" },
    }
    api = NexusDoubles::FakeAgentApi.new(inbox_tasks: [task],
      workspaces: [{ public_id: "0199-workspace", name: "Helper", dedicated: true }])
    cables = []
    daemon = boot(device_flow: connection_device_flow, api_transport: api,
      realtime_factory: ->(credential) {
        cable = CybrosAgent::TestSupport::FakeRealtime.new
        cables << [credential.call.to_s, cable]
        cable
      })
    token = connect(daemon)
    await_workspace_state(daemon, "adopted", token: token)
    wait_for { api.commits.length == 1 }
    services = api.announcements.last.fetch("services")
    assert_equal %w[agent runner], services.keys.sort
    assert_includes services.fetch("runner").fetch("tools").map { |entry| entry.fetch("name") }, "read"
    assert_empty api.runner_announcements
    assert_equal 0, api.runner_inbox_reads
    assert_equal ["read-local"], api.claims
    assert_equal "completed", api.commits.first.last.fetch("outcome")
    assert_includes api.commits.first.last.to_s, "application environment"
    wait_for { cables.any? { |_, cable| cable.subscriptions.any? } }
    inbox_cables = cables.select { |_, cable| cable.subscriptions.any? { |sub| sub.channel.end_with?("ExecutorInboxChannel") } }
    assert_equal [NexusDoubles::TRANSPORT_TOKEN], inbox_cables.map(&:first)
    assert_equal "0199-executor", daemon.identity.runner_executor_public_id
  end
end
