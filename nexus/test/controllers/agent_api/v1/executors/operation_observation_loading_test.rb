require "test_helper"

class AgentAPI::V1::Executors::OperationObservationLoadingTest < ActionDispatch::IntegrationTest
  setup do
    @human = users(:member)
    @workspace = workspaces(:shared)
    @runner = suite_runner
    @runner.announce(tools: RunAuthoringTestHelper::TEST_SERVED_TOOLS + [{
      "name" => "program", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
    }])
    @loop = seed(tool("program", "program", "route" => { "kind" => "runner" }, "model_defaults" => {
      "tools" => fixture_runner_declarations([RunLaneTestHelper::READ_TOOL]),
      "model" => { "model" => "dev/mock-text" },
    }))
    assert_predicate AgentRuns::Start.call(AgentRuns::Start::Command.new(agent_run: @loop, acting_user: @human)), :accepted?
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    @parent = @loop.agent_run_tasks.sole
    claim = Executors::Claim.call(Executors::Claim::Command.new(
      agent_run: @loop, task_key: @parent.node_key, executor: @runner))
    assert_predicate claim, :accepted?
    @parent = claim.value
  end

  ["pending", "one_ready", "all_ready"].each do |state|
    test "#{state} observation materializes bounded candidates at ten and one thousand pending operations" do
      counts = [10, 1_000].map do |width|
        measured = nil
        ApplicationRecord.transaction(requires_new: true) do
          children = seed_operations(width)
          ready = case state
          when "one_ready" then children.last(1)
          when "all_ready" then children
          else []
          end
          @loop.agent_run_tasks.where(node_key: ready).update_all(status: "completed", completed_at: Time.current)
          measured = capture_observation(width)
          assert_response :ok
          observation = response.parsed_body.fetch("observation")
          if ready.empty?
            assert_nil observation
          else
            index = state == "one_ready" ? width - 1 : 0
            assert_equal "op_#{index}", observation.fetch("key")
            assert_equal children.fetch(index), observation.dig("outcome", "task_key")
            assert_equal "completed", observation.dig("outcome", "status")
          end
          raise ActiveRecord::Rollback
        end
        measured
      end

      assert_operator counts.last.fetch(:records), :<=, counts.first.fetch(:records) + 64,
        "one observation must not instantiate the pending fan: #{counts.inspect}"
      assert_operator counts.last.fetch(:queries), :<=, counts.first.fetch(:queries) + 1, counts.inspect
    end
  end

  test "a later ready operation is observed beyond a page of terminal roots with unfinished replacements" do
    children = seed_operations(41)
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    children.first(40).each_with_index do |key, index|
      root = @loop.agent_run_tasks.find_by!(node_key: key)
      append_branch!(root, [tool("expanded-#{index}", "read_file", "route" => { "kind" => "runner" })], detached: false)
    end
    last = @loop.agent_run_tasks.find_by!(node_key: children.last)
    assert_predicate AgentRuns::Parks::Settle.call(node: last, trusted: true, content: "last ready"), :applied?

    observe(41)

    assert_response :ok
    assert_equal "op_40", response.parsed_body.dig("observation", "key")
    assert_equal "last ready", response.parsed_body.dig("observation", "outcome", "output")
    assert_equal 1, @parent.task_operations.where.not(observed_position: nil).count
  end

  test "a canceled replacement is observable before its transparent wrapper settles" do
    children = seed_operations(1)
    AgentRuns::ScheduleReady.call(agent_run_id: @loop.id)
    root = @loop.agent_run_tasks.find_by!(node_key: children.sole)
    # Kernel wrappers publish their append and settlement in separate transactions.
    # A cancellation can close the replacement during that real intermediate state.
    appended = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: @loop, steps: [AgentRuns::Tasks::Step::Tool.new(key: "replacement", name: "read_file",
        route: { "kind" => "runner" })], tip: AgentRuns::KernelTool.branch_tip(root),
      origin: "model", expansion_parent: root))
    assert_predicate appended, :applied?, appended.inspect
    replacement = @loop.agent_run_tasks.find_by!(node_key: "replacement")
    @loop.with_lock { AgentRuns::CancelBranch.cancel_locked(agent_run: @loop, targets: [replacement]) }
    assert_equal "dispatched", root.reload.status
    assert_equal "canceled", replacement.reload.status

    observe(1)

    assert_response :ok
    assert_equal "op_0", response.parsed_body.dig("observation", "key")
    assert_equal "replacement", response.parsed_body.dig("observation", "outcome", "task_key")
    assert_equal "canceled", response.parsed_body.dig("observation", "outcome", "status")
  end

  private

    # Copy one accepted operation's persisted shape to make fan-width read costs
    # independent of repeated admission, scheduling and HTTP setup.
    def seed_operations(width)
      access = Executors::TaskOperations::Access.new(agent_run: @loop, task_key: @parent.node_key,
        executor: @runner, claim_token: @parent.claim_token)
      submitted = Executors::TaskOperations::Submit.new(access: access, key: "op_0",
        request: { "kind" => "tool", "name" => "read_file", "input" => {} }).call
      assert_predicate submitted, :accepted?
      assert_nil submitted.value.dig("operation", "refusal")
      operation = @parent.task_operations.sole
      original_key = operation.response.fetch("receipt").fetch("result_task_keys").sole
      child = @loop.agent_run_tasks.find_by!(node_key: original_key)
      keys = Array.new(width - 1) { SecureRandom.uuid_v7 }
      if keys.any?
        attributes = child.attributes.except("id", "public_id", "node_key")
        AgentRunTask.insert_all!(keys.map { |key| attributes.merge("node_key" => key) })
        attributes = operation.attributes.except("id", "operation_key", "position", "response")
        AgentRunTaskOperation.insert_all!(keys.each_with_index.map do |key, index|
          receipt = operation.response.fetch("receipt").merge("task_keys" => [key], "result_task_keys" => [key])
          attributes.merge("operation_key" => "op_#{index + 1}", "position" => index + 2,
            "response" => { "receipt" => receipt })
        end)
      end
      [original_key, *keys]
    end

    def capture_observation(position)
      counts = { records: 0, queries: 0 }
      instances = ->(*, payload) { counts[:records] += payload.fetch(:record_count) }
      queries = ->(*, payload) do
        counts[:queries] += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION])
      end
      ActiveSupport::Notifications.subscribed(instances, "instantiation.active_record") do
        ActiveSupport::Notifications.subscribed(queries, "sql.active_record") { observe(position) }
      end
      counts
    end

    def observe(position)
      post "/agent_api/v1/executor/inbox/#{@loop.public_id}/#{@parent.node_key}/observation",
        params: { claim_token: @parent.claim_token, after: position },
        headers: { "Authorization" => "Bearer #{suite_runner_connection.executor_access_secret}" }, as: :json
    end
end
