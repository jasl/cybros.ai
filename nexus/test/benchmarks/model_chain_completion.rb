require "test_helper"
require "test_helpers/agent_run_api_test_helper"

# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/model_chain_completion.rb
# SAMPLES=3 by default. Real HTTP create/start and the model execution chain;
# only provider transport is fake. Compare both convergence scopes in one run.
# Measure scheduling, admission, execution and convergence separately from setup,
# verification and duplicate-wake checks. Rollbacks defer after-commit callbacks:
# these numbers exclude real commits, queue delivery and other queued wake jobs.
class ModelChainCompletionBenchmark < ActionDispatch::IntegrationTest
  include AgentRunAPITestHelper
  include ActiveJob::TestHelper
  include InvocationHarness

  SAMPLES = Integer(ENV.fetch("SAMPLES", "3"))
  WARMUPS = 1

  setup { DevModelLane.ensure_enabled!(@account) }

  test "compare global and targeted completion for serial and all-fan models" do
    %i[serial fan].each do |topology|
      keys = topology == :serial ? %w[first second finish] : %w[first second third finish]
      leaves = keys.map { |key| model(key, "prompt" => "Produce result #{key}") }
      steps = topology == :serial ? leaves : [parallel(*leaves.first(3)), leaves.last]
      agent_run = created_loop(steps)
      post "#{loops_path}/#{agent_run.public_id}/start", headers: auth
      assert_response :success
      assert_equal "running", response.parsed_body.dig("agent_run", "status")
      clear_enqueued_jobs
      samples = { global: [], targeted: [] }
      expected = nil
      (WARMUPS + SAMPLES).times do |index|
        order = index.even? ? %i[global targeted] : %i[targeted global]
        order.each do |scope|
          sample, snapshot = complete_sample(agent_run, keys, scope)
          expected ||= snapshot
          assert_equal expected, snapshot, "convergence scope must preserve every request, dependency and result"
          samples.fetch(scope) << sample if index >= WARMUPS
        end
      end
      samples.each do |scope, measurements|
        puts JSON.generate(operation: "model_chain_completion", topology: topology,
          convergence: scope, model_tasks: keys.length, warmups: WARMUPS, samples: measurements)
      end
    end
  end

  private

    def complete_sample(agent_run, keys, scope)
      counts = { elapsed_ms: 0.0, allocations: 0, sql: Hash.new(0) }
      requests = {}
      snapshot = nil
      ApplicationRecord.transaction(requires_new: true) do
        GC.start
        measure(counts) { AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) }
        # Every pass executes at least one new authored model; there are only keys.length.
        until requests.length == keys.length
          admitted = measure(counts) { ModelInvocations::AdmitQueuedWork.call.admitted }
          assert_not_empty admitted, "an unfinished graph must expose its next model work"
          admitted.reverse_each do |candidate|
            invocation = candidate.invocation
            assert_equal agent_run.id, invocation.agent_run_id
            node = agent_run.agent_run_tasks.find_by!(selected_model_invocation_id: invocation.id)
            assert_not requests.key?(node.node_key), "one provider call per model task"
            sources = node.sources.to_a
            assert sources.all? { |source| source.status == "completed" },
              "a model may run only after all its dependencies"
            fake_dispatch(sse_success("result #{node.node_key}")) do |adapter|
              measure(counts) { ModelInvocations::RunJob.perform_now(candidate.attempt.public_id) }
              requests[node.node_key] = adapter.requests.sole.fetch(:body)
            end
            sources.each do |source|
              assert_includes requests.fetch(node.node_key), "Mock: result #{source.node_key}"
            end
            # Both scopes receive exactly one convergence and schedule wake per result.
            measure(counts) { converge(scope, invocation.id) }
            measure(counts) { AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id) }
          end
        end
        snapshot = verify_completion(agent_run, keys, requests, scope)
        raise ActiveRecord::Rollback
      end
      clear_enqueued_jobs
      [counts.merge(elapsed_ms: counts.fetch(:elapsed_ms).round(3)), snapshot]
    end

    def verify_completion(agent_run, keys, requests, scope)
      assert_equal "completed", agent_run.reload.status
      nodes = agent_run.agent_run_tasks.order(:node_key).includes(:sources).to_a
      assert_equal keys.sort, nodes.map(&:node_key)
      assert nodes.all? { |node| node.status == "completed" }
      assert_equal "Mock: result finish", agent_run.deliverable_node.output_body.effective_text
      invocations = agent_run.model_invocations.order(:id).to_a
      assert_equal keys.length, invocations.length
      assert invocations.all? { |invocation| invocation.completed? && invocation.terminal_event_recorded_at }
      attempts = ModelInvocationAttempt.where(model_invocation_id: invocations.map(&:id)).to_a
      assert_equal invocations.map(&:id).sort, attempts.map(&:model_invocation_id).sort,
        "every node must have exactly one attempt"
      fake_dispatch(sse_success("unexpected duplicate")) do |adapter|
        invocations.each { |invocation| converge(scope, invocation.id) }
        AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
        assert_empty ModelInvocations::AdmitQueuedWork.call.admitted
        attempts.each { |attempt| ModelInvocations::RunJob.perform_now(attempt.public_id) }
        assert_empty adapter.requests, "duplicate completion and execution wakes must not call the provider"
      end
      assert_equal invocations.map(&:id), agent_run.model_invocations.order(:id).pluck(:id)
      {
        requests: requests,
        tasks: nodes.to_h do |node|
          [node.node_key, { dependencies: node.sources.map(&:node_key).sort,
                           output: node.output_body.effective_text }]
        end,
      }
    end

    def converge(scope, invocation_id)
      AgentRuns::ConvergeTerminalSteps.call(invocation_id: scope == :targeted ? invocation_id : nil)
    end

    def measure(counts)
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].in?(%w[SCHEMA CACHE]) || payload[:cached]

        verb = payload.fetch(:sql).lstrip.split(/\s+/, 2).first.upcase
        counts.fetch(:sql)[verb] += 1 if %w[SELECT INSERT UPDATE DELETE].include?(verb)
      end
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ApplicationRecord.uncached { yield }
    ensure
      counts[:elapsed_ms] += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
      counts[:allocations] += GC.stat(:total_allocated_objects) - allocated
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
end
