require_relative "../test_helper"
require_relative "../support/ops_harness"

class OpsRealtimeTest < Minitest::Test
  include RhoTest::OpsHarness

  class Api < NexusDoubles::FakeAgentApi
    attr_reader :signals
    attr_accessor :denied

    def initialize
      super
      @signals = []
    end

    def call(path, **options)
      if path.end_with?("/realtime", "/cancel")
        @signals << [path, options]
        if @denied
          return CybrosAgent::Response.new(status: 403, headers: {}, body: { "error" => { "code" => "not_authorized" } })
        end
        body = if path.end_with?("/realtime")
          { realtime: { status: "waiting", reason: "answer_required", connection_id: "peer", offer_sdp: "offer", answer_sdp: nil, max_age_ms: 0 } }
        else
          { task: NexusDoubles::RUNNING_TRACE.fetch("tasks").first.merge("status" => "canceled") }
        end
        CybrosAgent::Response.new(status: 200, headers: {}, body: JSON.parse(JSON.generate(body)))
      else
        super
      end
    end
  end

  def test_signal_and_cancel_use_the_original_member_task_without_creating_execution
    api = Api.new
    daemon = member_ready(boot, api)
    target = { public_id: "al-9", task_key: "work" }
    get = request(daemon, :get, "/runs/task/realtime?public_id=al-9&task_key=work", token: bearer(daemon))
    assert_equal "200", get.code, get.body
    assert_equal "no-store", get["cache-control"]
    assert_equal "offer", JSON.parse(get.body).dig("realtime", "offer_sdp")
    put = request(daemon, :put, "/runs/task/realtime", token: bearer(daemon), body: target.merge(connection_id: "peer", sdp: "answer"))
    assert_equal "200", put.code, put.body
    assert_equal({ "connection_id" => "peer", "sdp" => "answer" }, api.signals.last.last.fetch(:body))
    stop = request(daemon, :post, "/runs/task/cancel", token: bearer(daemon), body: target)
    assert_equal "200", stop.code, stop.body
    assert_equal "canceled", JSON.parse(stop.body).dig("task", "status")
    assert api.signals.all? { |path, options| path.include?("/runs/al-9/tasks/work/") && options[:credential] == NexusDoubles::MEMBER_TOKEN }
  end

  def test_authentication_and_kernel_refusal_still_gate_terminal_commands
    api = Api.new
    daemon = member_ready(boot, api)
    response = request(daemon, :get, "/runs/task/realtime?public_id=al-9&task_key=work")
    assert_equal "401", response.code
    assert_empty api.signals
    api.denied = true
    response = request(daemon, :get, "/runs/task/realtime?public_id=al-9&task_key=work", token: bearer(daemon))
    assert_equal "403", response.code, response.body
  end
end
