require "test_helper"
require "json"
require "securerandom"
require "support/actor_provisioning"
require "support/sdk_process"

class SDKDecisionsTest < Minitest::Test
  def setup
    E2E::SDKProcess.prepare!
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(name: "SDK Decisions", idempotency_key: SecureRandom.uuid).workspace
    @requests = @client.workspace(@workspace.public_id).inference_requests
  end

  def teardown
    if @workspace
      @requests.list.items.each { |request| @requests.cancel(request.public_id) }
      current = @client.workspaces.fetch(@workspace.public_id)
      @client.workspace(@workspace.public_id).delete(lock_version: current.lock_version)
    end
  end

  def test_ruby_decisions_create_wait_and_read_answers_and_usage
    exercise(:ruby)
  end

  def test_typescript_decisions_create_wait_and_read_answers_and_usage
    exercise(:typescript)
  end

  def test_rust_decisions_create_wait_and_read_answers_and_usage
    exercise(:rust)
  end

  private

    def exercise(language)
      # Both local wires run for each SDK; no external model or credential is selected.
      ["dev/mock-decision", "dev/mock-system-one"].each do |model|
        payload = {
          action: "member_decision", base_url: @base_url, credential: @actor.member_token,
          workspace_public_id: @workspace.public_id, input_key: SecureRandom.uuid, model:,
          decision_input: { eligible: false, category: "blue", rating: 0.75 },
          questions: [
            { name: "eligible", type: "predicate", instructions: "Read eligible." },
            { name: "category", type: "choice", instructions: "Read category.",
              choices: [{ value: "red", description: "Red" }, { value: "blue", description: "Blue" }] },
            { name: "rating", type: "score", instructions: "Read rating.",
              levels: [{ label: "low", description: "Low" }, { label: "high", description: "High" }] },
          ],
        }
        facts = language == :ruby ? ruby_decision(payload) : E2E::SDKProcess.run(language, payload)
        assert_equal 202, facts.fetch("create_status") unless language == :ruby
        assert_decision(facts, model)
      end
    end

    def ruby_decision(payload)
      created = @requests.create(workload: "decision", model: payload.fetch(:model),
        input: payload.fetch(:decision_input), configuration: { questions: payload.fetch(:questions) },
        idempotency_key: payload.fetch(:input_key))
      refute_predicate created, :replayed?
      refute_predicate created, :finished?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      loop do
        row = @requests.fetch(created.public_id)
        if row.finished?
          return JSON.parse(JSON.generate({
            public_id: created.public_id, fetched_public_id: row.public_id,
            status: row.status, result_status: row.result.status, error: row.result.error,
            answers: row.result.answers&.map(&:to_h), usage: row.result.usage&.to_h,
          }))
        end
        flunk("Decision #{created.public_id} did not finish") if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.1
      end
    end

    def assert_decision(facts, model)
      assert_equal facts.fetch("public_id"), facts.fetch("fetched_public_id")
      assert_equal "completed", facts.fetch("status"), facts.inspect
      assert_equal "completed", facts.fetch("result_status")
      assert_nil facts.fetch("error")
      answers = facts.fetch("answers")
      assert_equal %w[eligible category rating], answers.map { |answer| answer.fetch("name") }
      assert_equal %w[predicate choice score], answers.map { |answer| answer.fetch("type") }
      assert_equal 0.0, answers[0].fetch("probability")
      assert_equal "blue", answers[1].fetch("choice")
      assert_equal 1.0, answers[1].fetch("confidence")
      assert_equal [["red", 0.0], ["blue", 1.0]],
        answers[1].fetch("probabilities").map { |row| row.values_at("value", "probability") }
      assert_equal 0.75, answers[2].fetch("score")
      assert_equal 0.75, answers[2].fetch("confidence")
      assert_equal [[0, "low", 0.25], [1, "high", 0.75]],
        answers[2].fetch("probabilities").map { |row| row.values_at("value", "label", "probability") }
      usage = facts.fetch("usage")
      expected = model == "dev/mock-decision" ? [41, 0, 41] : [43, 7, 50]
      assert_equal expected, usage.values_at("input_tokens", "output_tokens", "total_tokens")
      assert_match(/\A[0-9a-f-]{36}\z/, usage.fetch("usage_record_public_id"))
      # A fresh SDK read must recover the same persisted receipt and answer, by exact UUID.
      recovered = @requests.fetch(facts.fetch("public_id"))
      assert_equal usage.fetch("usage_record_public_id"), recovered.result.usage.usage_record_public_id
      assert_equal 0.75, recovered.result.answers.last.score
    end
end
