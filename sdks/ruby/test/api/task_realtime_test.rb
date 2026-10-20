require "test_helper"

class ApiTaskRealtimeTest < Minitest::Test
  def test_both_planes_share_the_projection_without_sharing_credentials
    body = JSON.parse(File.read(File.expand_path("../../../../contracts/nexus/v1/executor_inbox.json", __dir__))).fetch("realtime_fixture")
    transport = CybrosAgentTest::FakeTransport.new(Array.new(4) { [200, {}, body] })
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://nexus.test", credential: "transport", transport: transport)
    member = CybrosAgent::Client.new(base_url: "http://nexus.test", credential: "member", transport: transport)
    task = executor.inbox_task(run_public_id: "run", task_key: "tool")
    member_task = member.workspace("workspace").run("run").tasks_context("tool")
    assert_predicate task.offer_realtime(claim_token: "proof", connection_id: "connection", sdp: "offer"), :active?
    assert_equal body.fetch("realtime").fetch("answer_sdp"), task.realtime(claim_token: "proof").answer_sdp
    assert_equal body.fetch("realtime").fetch("offer_sdp"), member_task.realtime.offer_sdp
    assert_equal 1000, member_task.answer_realtime(connection_id: "connection", sdp: "answer").max_age_ms
    assert_equal [:put, :get, :get, :put], transport.requests.map { |request| request.fetch(:method) }
    assert_equal %w[transport transport member member], transport.requests.map { |request| request.fetch(:credential) }
    transport.requests.first(2).each do |request|
      assert_equal({ "Claim-Token" => "proof" }, request.fetch(:headers))
      refute_includes request.fetch(:path), "proof"
    end
    transport.requests.last(2).each { |request| refute request.fetch(:headers, {}).key?("Claim-Token") }
  end
end
