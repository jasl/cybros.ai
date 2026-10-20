module E2E
  # Exercise the ordinary claim/commit path in the same pool as a live realtime task.
  module RealtimeConcurrentWork
    private

      def assert_realtime_concurrent_read(task_run:, runs:, executor_id:, root:)
        words = "Read while realtime work continues: #{SecureRandom.uuid}"
        File.write(File.join(root, "concurrent-read.txt"), words)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = nil
        Async::Task.current.with_timeout(5) do
          run = runs.start_tool_call(runner_executor_public_id: executor_id, tool: "read",
            input: { "path" => "concurrent-read.txt" }, idempotency_key: SecureRandom.uuid)
          key = CybrosAgent::Api::RunContext::TOOL_CALL_TASK_KEY
          await { run.task(key).task.status == "dispatched" }
          assert_equal :done, task_run.call(run_public_id: run.run_public_id, task_key: key, tool_name: "read")
          detail = run.task(key)
          assert_equal "completed", detail.task.status
          assert_equal executor_id, detail.task.target.executor_public_id
          assert_equal executor_id, detail.task.claimed_by.executor_public_id
          assert_equal words, detail.content.map { |block| block.fetch("text") }.join
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_operator elapsed, :<, 5
        warn "REALTIME_CONCURRENT_READ_SECONDS #{elapsed}"
      ensure
        run.stop(force: true) if run && !run.fetch.terminal?
      end
  end
end
