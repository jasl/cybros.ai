require "test_helper"

class AgentAPI::V1::OneShotInputEstimatesTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @workspace = workspaces(:shared)
    DevModelLane.ensure_enabled!(@account)
    token = create_access_token_fixture(user: @human, name: "Input estimate")
    @headers = { "Authorization" => "Bearer #{token.secret}" }
  end

  test "returns an advisory estimate without creating model work" do
    counts = persisted_counts

    post estimate_path, headers: @headers, as: :json, params: payload("hello")

    assert_response :success
    assert_equal counts, persisted_counts
    estimate = response.parsed_body.fetch("input_estimate")
    assert_equal 1 + ModelRequests::TokenCount::ENVELOPE_TOKENS_FIXED +
      ModelRequests::TokenCount::ENVELOPE_TOKENS_PER_SEGMENT,
      estimate.fetch("input_tokens")
    assert estimate.fetch("tokenizer_exact")
    assert_equal 8192, estimate.fetch("catalog_input_token_limit")
    assert_not estimate.key?("advisory_input_token_limit")
    assert_equal(
      { "provider_id" => "dev", "model_ref" => "mock-text", "reasoning_effort" => "medium" },
      estimate.fetch("model")
    )
  end

  test "returns the same typed selection refusal as create" do
    counts = persisted_counts

    post estimate_path, headers: @headers, as: :json,
      params: payload("hello", model: "dev/not-a-model")

    assert_response :unprocessable_entity
    assert_equal "unknown_model", response.parsed_body.dig("error", "code")
    assert_equal counts, persisted_counts
  end

  test "does not add Create's canonical storage checks to the write-free advisory" do
    post estimate_path, headers: @headers, as: :json, params: payload("a\u0000b")

    assert_response :success
    assert_operator response.parsed_body.dig("input_estimate", "input_tokens"), :>, 0
  end

  test "requires its typed root" do
    post estimate_path, headers: @headers, as: :json,
      params: { workload: "text_generation", model: { model: "dev/mock-text" }, input: "hello" }

    assert_response :bad_request
  end

  private

    def estimate_path
      "/agent_api/v1/workspaces/#{@workspace.public_id}/one_shots/input_estimate"
    end

    def payload(input, model: "dev/mock-text")
      {
        input_estimate: {
          workload: "text_generation",
          model: { model: model },
          input: input,
        },
      }
    end

    def persisted_counts
      [OneShot.count, ModelInvocation.count, OneShotCreateReceipt.count, ContentBody.count]
    end
end
