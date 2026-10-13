require "test_helper"
require_relative "../support/run_fixtures"

class ApiRunSpeakersTest < Minitest::Test
  include CybrosAgentTest::RunFixtures

  def test_create_passes_the_selected_speaker_and_preserves_explicit_null
    fixture = CybrosAgentTest::ContractFixtures.pack("runs.json").fetch("valid_ingress_create_request").fetch("run")
    [fixture.fetch("speaker_public_id"), nil].each do |speaker_id|
      workspace([[201, {}, { "run" => RUN, "receipt" => { "revision" => 1 } }]]).runs.create(
        steps: fixture.fetch("steps"), prompt_mechanism: fixture.fetch("prompt_mechanism"),
        idempotency_key: "seed-1", approval_mode: fixture.fetch("approval_mode"), speaker_public_id: speaker_id
      )
      assert_equal :post, request.fetch(:method)
      assert_equal RUNS_PATH, request.fetch(:path)
      assert_equal fixture.merge("speaker_public_id" => speaker_id), request.fetch(:body).fetch("run")
    end
  end

  def test_create_omits_the_speaker_selector_unless_supplied
    workspace([[201, {}, { "run" => RUN, "receipt" => { "revision" => 1 } }]]).runs.create(
      steps: [{ "model" => { "key" => "round1", "prompt" => "p" } }],
      idempotency_key: "seed-1", approval_mode: "bypass"
    )
    refute request.fetch(:body).fetch("run").key?("speaker_public_id")
  end

  def test_run_detail_reads_the_original_requester_and_preserves_unknown
    ["requester-speaker", nil].each do |speaker_id|
      run = workspace([[200, {}, { "run" => RUN.merge("requester_speaker_public_id" => speaker_id) }]])
        .run(RUN_ID).fetch

      if speaker_id
        assert_equal speaker_id, run.requester_speaker_public_id
      else
        assert_nil run.requester_speaker_public_id
      end
    end
    listed = workspace([[200, {}, { "runs" => [RUN], "pagination" => { "next_after" => nil } }]])
      .runs.list.items.fetch(0)
    assert_nil listed.requester_speaker_public_id
  end
end
