require "test_helper"

# Model selection: the dev/mock lane resolves through
# the REAL resolver over the mounted test-owned catalog — same policy gate,
# credentialless credential resolution, and selection path as any configured
# provider. This is what unparked WP7d.
class ModelSelection::DevLaneTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "all five workloads resolve one truthful dev candidate lane" do
    expected_routes = {
      "text_generation" => "responses_http_sse",
      "image_generation" => "images_generations_http",
      "speech_generation" => "audio_speech_http",
      "transcription" => "audio_transcriptions_http_multipart",
      "embedding" => "embeddings_http",
    }

    expected_routes.each do |workload, route|
      result = DevModelLane.resolve(workload: workload, account: @account)

      assert_predicate result, :resolved?, "#{workload}: #{result.refusal.inspect}"
      selection = result.selection
      assert_equal workload, selection.workload
      assert_equal route, selection.execution_profile.protocol_route
      assert_equal "none", selection.execution_profile.credential_lane
    end
  end

  test "the lane gate still applies to the credentialless lane" do
    # Order-proof: a non-transactional test elsewhere may have committed the
    # dev enablement; this test's subject is the gate, so clear the lane
    # inside this test's own transaction.
    ModelProviderPolicy.where(account: @account, provider_id: "dev").delete_all

    result = ModelSelection::Resolver.new.resolve(
      account: @account, workload: "text_generation",
      submitted: DevModelLane.submission_for("text_generation")
    )

    assert_equal :provider_disabled, result.refusal
  end

  test "the fast-text selector and the priced fixture model resolve" do
    selector = DevModelLane.resolve(
      workload: "text_generation", account: @account,
      submitted: Nexus::SubmittedModelSelection.new(
        model: "model_selector:fast-text", reasoning_effort: nil
      )
    )

    assert_predicate selector, :resolved?
    assert_equal "low", selector.selection.reasoning.effort

    priced = DevModelLane.selection(
      workload: "text_generation", account: @account, model: DevModelLane::PRICED_TEXT_MODEL
    )
    assert_equal "mock-priced", priced.execution_profile.model_pin
  end

  test "configuration normalizes against the definitional dev contracts" do
    accepted = DevModelLane.selection(
      workload: "text_generation", account: @account,
      configuration: { temperature: 0.5, max_output_tokens: 512 }
    )
    assert_equal 0.5, accepted.generation_config.fetch(:temperature)

    out_of_range = DevModelLane.resolve(
      workload: "text_generation", account: @account,
      configuration: { temperature: 9.0 }
    )
    refute_predicate out_of_range, :resolved?
  end
end
