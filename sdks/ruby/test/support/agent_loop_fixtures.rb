module CybrosAgentTest
  module AgentLoopFixtures
    WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
    LOOP_ID = "019f0000-0000-7000-8000-000000000601".freeze
    LOOPS_PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/agent_loops".freeze
    LOOP_PATH = "#{LOOPS_PATH}/#{LOOP_ID}".freeze

    # The trace as the presenter builds it — COMPACTED, which is the reading
    # rule that matters: absent means "no value", never "the server forgot".
    TASK = {
      "key" => "round1",
      "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto",
      "status" => "waiting",
      "on_failure" => "halt",
      "visibility" => "visible",
      "created_at" => "2026-09-02T00:00:00Z",
    }.freeze

    LOOP = {
      "public_id" => LOOP_ID,
      "status" => "pending",
      "deliverable_task_key" => "round1",
      "tasks" => [TASK],
      "task_progress" => { "total" => 1, "waiting" => 1 },
      "created_at" => "2026-09-02T00:00:00Z",
      "updated_at" => "2026-09-02T00:00:00Z",
    }.freeze

    def workspace(script)
      @transport = CybrosAgentTest::FakeTransport.new(script)
      CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member",
        transport: @transport).workspace(WORKSPACE_ID)
    end

    def request(index = 0) = @transport.requests.fetch(index)
  end
end
