require_relative "test_helper"

class SessionTest < Minitest::Test
  Client = Data.define(:scope) do
    def workspace(_) = scope
  end
  Plane = Data.define(:client, :workspace_public_id)

  def test_cancel_addresses_the_saved_owner_on_the_existing_member_plane
    calls = []
    session = session_with(lambda { |path, **args|
      calls << [path, args]
      { "task" => task("canceled") }
    })

    session.cancel("run" => "original-run", "task" => "delegate")

    assert_equal [["/agent_api/v1/workspaces/workspace/runs/original-run/tasks/delegate/cancel", { method: :post }]], calls
  end

  def test_a_missing_or_already_terminal_owner_needs_no_further_cancel
    [CybrosAgent::Api::NotFound.new(code: "not_found"),
      CybrosAgent::Api::Conflict.new(code: "already_terminal")].each do |error|
      calls = 0
      session = session_with(->(*) { calls += 1; raise error })
      session.cancel("run" => "original-run", "task" => "delegate")
      assert_equal 1, calls
    end
  end

  def test_an_unadjudicable_owner_is_ignored_only_after_its_task_is_terminal
    %w[canceled dispatched].each do |status|
      calls = []
      error = CybrosAgent::Api::Conflict.new(code: "not_adjudicable")
      session = session_with(lambda { |path, **|
        calls << path
        raise error if path.end_with?("/cancel")

        { "task" => task(status) }
      })
      if status == "canceled"
        session.cancel("run" => "original-run", "task" => "delegate")
      else
        assert_same error, assert_raises(CybrosAgent::Api::Conflict) { session.cancel("run" => "original-run", "task" => "delegate") }
      end
      assert_equal ["/agent_api/v1/workspaces/workspace/runs/original-run/tasks/delegate/cancel",
        "/agent_api/v1/workspaces/workspace/runs/original-run/tasks/delegate"], calls
    end
  end

  def test_other_owner_cancellation_failures_remain_visible
    [CybrosAgent::Api::Conflict.new(code: "not_a_branch"),
      CybrosAgent::Api::Forbidden.new(code: "not_authorized"), CybrosAgent::TransportError.new("response lost")].each do |error|
      session = session_with(->(*) { raise error })
      assert_same error, assert_raises(error.class) { session.cancel("run" => "original-run", "task" => "delegate") }
    end
  end

  private

    def session_with(dispatch)
      workspace = CybrosAgent::Api::WorkspaceContext.new(dispatch: dispatch, public_id: "workspace")
      plane = Plane.new(client: Client.new(scope: workspace), workspace_public_id: "workspace")
      context = Rho::Runner::ExecutionContext.new(run_public_id: "control-run", task_key: "stop",
        conversation_public_id: "conversation", workspace_public_id: "workspace")
      Rho::T3::Session.new(member_plane: ->(**) { plane }, context: context)
    end

    def task(status)
      { "key" => "delegate", "kind" => "tool_task", "status" => status, "lifetime" => "conversation", "wake" => "passive" }
    end
end
