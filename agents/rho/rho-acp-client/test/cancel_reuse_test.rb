require "test_helper"

# A conforming child may finish cleanup after the runner's cancellation
# grace. Its final updates still belong to that prompt, even when the next
# delegation continues the same ACP session.
class CancelReuseTest < Minitest::Test
  include RhoAcpClientTest::Helpers

  AGENT = File.expand_path("support/deferred_cancel_agent.rb", __dir__)

  def setup
    Rho::AcpClient.settings_table = {
      "deferred" => { "command" => Gem.ruby, "args" => [AGENT], "description" => "a deferred cancellation fixture" },
    }
    host = Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-acp-reuse-test")),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil
    )
    loaded = Rho::Runner::Extensions::Loader.call(gems: ["rho/acp-client"], api_class: Rho::Extensions::Api,
      api_options: { host: host })
    assert_predicate loaded, :ok?, loaded.failures.inspect
  end

  def teardown = Rho::AcpClient.reset!

  def test_a_finished_cancelled_prompt_cannot_contribute_text_to_the_next_delegation
    with_cancelled_prompt do |env, row, gate|
      File.write(gate, "")
      assert await(seconds: 3) {
        capture_lines(row.fetch("capture")).any? { |line| line.dig("message", "result", "stopReason") == "cancelled" }
      }, "the old prompt has answered before the next call starts"

      result = continue_session(env, row)
      refute_predicate result, :is_error, result.content
      assert_equal "echo: new-answer", result.content.split("\n\n").first
      assert_equal row.fetch("session"), result.structured_content.fetch("session")
      assert process_group_alive?(row.fetch("pgid")), "an ordinary cancel preserves the child"
    end
  end

  def test_a_prompt_still_finishing_cancellation_does_not_admit_a_new_request
    with_cancelled_prompt do |env, row, _gate|
      result = continue_session(env, row)
      assert_predicate result, :is_error
      assert_includes result.content, "still finishing its cancelled delegation"
      prompts = capture_lines(row.fetch("capture")).select { |line| line.dig("message", "method") == "session/prompt" }
      assert_equal 1, prompts.length, "the child must finish its old prompt before a new request can reach it"
      assert process_group_alive?(row.fetch("pgid"))
    end
  end

  private

    def with_cancelled_prompt
      with_tool_env do |env, root, context|
        gate = File.join(root, "release-old-prompt")
        worker = Thread.new do
          Rho::Runner::ExecutionContext.with(context) do
            Rho::AcpClient.call({ "agent" => "deferred", "prompt" => "defer:#{gate}" }, env: env)
          end
        rescue Rho::Runner::ExecutionContext::Cancelled => error
          error.reason
        end
        row = await(seconds: 3) do
          candidate = Rho::AcpClient.report.fetch("sessions").first
          candidate if candidate && File.read(candidate.fetch("capture")).include?("old-head")
        end
        refute_nil row, "the first prompt is running on the child"
        context.cancel(:canceled)
        assert worker.join(3), "cancellation returns within the pool's grace"
        assert_equal :canceled, worker.value
        yield env, row, gate
      ensure
        File.write(gate, "") if gate
        worker&.join(3)
      end
    end

    def continue_session(env, row)
      context = Rho::Runner::ExecutionContext.new(conversation_public_id: "conv-1", task_key: "next-call",
        run_public_id: "loop-1")
      Rho::Runner::ExecutionContext.with(context) do
        Rho::AcpClient.call({ "agent" => "deferred", "session" => row.fetch("session"), "prompt" => "new-answer" }, env: env)
      end
    end
end
