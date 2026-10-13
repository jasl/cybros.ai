require "test_helper"
require "pp"
require_relative "../support/contract_fixtures"

# A Workspace's nested InferenceRequest surface: one direct model call.
#
# The fixtures come from the Nexus-owned contract pack rather than from hand-
# written literals here, so a wire change that Nexus regenerates fails in this
# suite instead of in production. What the tests below add on top of the pack
# is the SDK's own contract: which shapes are parsed strictly, which are read
# by presence, and what a caller is allowed to conclude from each.
class ApiInferenceRequestsTest < Minitest::Test
  WORKSPACE_ID = "019f0000-0000-7000-8000-000000000101".freeze
  PATH = "/agent_api/v1/workspaces/#{WORKSPACE_ID}/inference_requests".freeze

  def contract = CybrosAgentTest::ContractFixtures.pack("inference_requests.json")

  def inference_requests(script)
    @transport = CybrosAgentTest::FakeTransport.new(script)
    CybrosAgent::Client.new(base_url: "http://example.test", credential: "sk-member", transport: @transport)
      .workspace(WORKSPACE_ID)
      .inference_requests
  end

  def request(index = 0)
    @transport.requests.fetch(index)
  end

  def test_input_estimate_uses_the_pre_create_resource_and_typed_projection
    estimate = inference_requests([[200, {}, contract.fetch("valid_input_estimate_fixture")]])
      .estimate_input(
        workload: "text_generation", model: "dev/text", input: "Say hi",
        reasoning_effort: "medium", configuration: { "temperature" => 0.2 }
      )

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/input_estimate", request.fetch(:path)
    fields = request.fetch(:body).fetch("input_estimate")
    assert_equal "Say hi", fields.fetch("input")
    assert_equal({ "model" => "dev/text", "reasoning_effort" => "medium" },
      fields.fetch("model"))
    assert_equal 24, estimate.input_tokens
    assert_predicate estimate, :tokenizer_exact?
    assert_equal 128_000, estimate.catalog_input_token_limit
    assert_equal 100_000, estimate.advisory_input_token_limit
    assert_equal "dev", estimate.model.provider_id
  end

  def test_create_sends_the_payload_envelope_and_the_callers_own_key
    accepted = inference_requests([[202, {}, contract.fetch("valid_queued_fixture")]]).create(
      workload: "text_generation", model: "dev/text", input: "Say hi",
      reasoning_effort: "medium", configuration: { "temperature" => 0.2 },
      idempotency_key: "key-1"
    )

    assert_equal :post, request.fetch(:method)
    assert_equal PATH, request.fetch(:path)
    assert_equal "key-1", request.fetch(:headers).fetch("Idempotency-Key")
    fields = request.fetch(:body).fetch("inference_request")
    assert_equal "text_generation", fields.fetch("workload")
    assert_equal({ "model" => "dev/text", "reasoning_effort" => "medium" }, fields.fetch("model"))
    assert_equal "Say hi", fields.fetch("input")
    assert_equal({ "temperature" => 0.2 }, fields.fetch("configuration"))
    refute accepted.replayed?, "202 is new work, not a recognized receipt"
    assert_equal "queued", accepted.status
  end

  def test_an_omitted_option_sends_no_field_at_all
    inference_requests([[202, {}, contract.fetch("valid_queued_fixture")]])
      .create(workload: "embedding", model: "dev/embedding",
              input: "embed me", idempotency_key: "key-2")

    fields = request.fetch(:body).fetch("inference_request")
    assert_equal %w[workload model input], fields.keys,
      "an unset option is absent, never a null the server has to interpret"
    assert_equal({ "model" => "dev/embedding" }, fields.fetch("model"))
  end

  # An explicit nil is a DIFFERENT statement from omission and must survive as
  # JSON null: `billing_subject: nil` is the caller saying "no subject", which
  # the server judges, rather than the caller saying nothing.
  def test_an_explicit_nil_travels_as_null
    inference_requests([[202, {}, contract.fetch("valid_queued_fixture")]])
      .create(workload: "text_generation", model: "dev/text", input: "hi",
              billing_subject: nil, idempotency_key: "key-3")

    fields = request.fetch(:body).fetch("inference_request")
    assert fields.key?("billing_subject")
    assert_nil fields.fetch("billing_subject")
  end

  def test_creation_demands_the_callers_own_idempotency_key
    error = assert_raises(ArgumentError) do
      inference_requests([]).create(workload: "text_generation", model: "dev/text",
                           input: "hi", idempotency_key: "")
    end

    assert_match(/idempotency_key/, error.message)
    assert_empty @transport.requests, "the guard runs before transport"
  end

  # THE RECEIPT'S WHOLE POINT: an exact repeat is a 200 carrying the standing
  # resource, not a refusal and not a second run. A caller that could not tell
  # the two apart could not tell whether it had just spent money twice.
  def test_a_replay_is_a_success_the_caller_can_recognize
    accepted = inference_requests([[200, {}, contract.fetch("valid_queued_fixture")]])
      .create(workload: "text_generation", model: "dev/text", input: "hi",
              idempotency_key: "key-1")

    assert accepted.replayed?
    assert_equal contract.dig("valid_queued_fixture", "inference_request", "public_id"), accepted.public_id
  end

  def test_an_unexpected_success_status_is_a_malformed_response
    assert_raises(CybrosAgent::Api::MalformedResponse) do
      inference_requests([[201, {}, contract.fetch("valid_queued_fixture")]])
        .create(workload: "text_generation", model: "dev/text", input: "hi",
                idempotency_key: "key-1")
    end
  end

  # TERMINALITY IS `result`, NOT A STATUS LIST. The queued fixture and the
  # completed one are told apart by presence alone, which is the property that
  # keeps this gem working against a Nexus that learns a new terminal status.
  def test_finished_is_read_from_the_result_envelope
    queued = inference_requests([[200, {}, contract.fetch("valid_queued_fixture")]]).fetch("os-1")
    done = inference_requests([[200, {}, contract.fetch("valid_fixture")]]).fetch("os-1")

    refute_predicate queued, :finished?
    assert_nil queued.result
    assert_nil queued.output_text
    assert_predicate done, :finished?
    assert_equal contract.dig("valid_fixture", "inference_request", "result", "output_text"), done.output_text
    assert_equal "#{PATH}/os-1", request.fetch(:path)
  end

  def test_an_unknown_status_or_workload_is_carried_rather_than_rejected
    unknown = CybrosAgentTest::ContractFixtures.pack("meta.json").fetch("unknown_value_fixture")
    status = inference_requests([[200, {}, { "inference_request" => contract.fetch("unknown_status_fixture") }]])
    workload = inference_requests([[200, {}, {
      "inference_requests" => [contract.fetch("unknown_workload_fixture")],
      "pagination" => { "next_after" => nil },
    }]])

    assert_equal unknown, status.fetch("os-1").status,
      "an execution status this gem predates must not stop it reading the run"
    assert_equal unknown, workload.list.items.fetch(0).workload
  end

  # A cut-off answer is a SUCCESS with a caveat: the quality sits beside the
  # status, `error` stays absent, and the text it did produce is the answer.
  def test_a_truncated_run_is_completed_with_a_caveat_beside_the_status
    result = inference_requests([[200, {}, contract.fetch("valid_truncated_fixture")]]).fetch("os-1").result

    assert_equal "completed", result.status
    assert_predicate result, :truncated?
    refute_predicate result, :failed?
    assert_nil result.error
    refute_empty result.output_text
  end

  # A DECLINED ANSWER FAILED THE RUN: never a truncation, though its quality
  # rides the same sibling slot — `refused?` asks it, the category beside it.
  def test_a_refused_run_failed_with_its_category_and_is_no_truncation
    result = inference_requests([[200, {}, contract.fetch("valid_refused_fixture")]]).fetch("os-1").result

    assert_equal "failed", result.status
    assert_predicate result, :refused?
    assert_predicate result, :failed?
    refute_predicate result, :truncated?
    assert_equal "model_refused", result.error.code
    assert_equal "cyber", result.refusal_category
    assert_nil result.output_text

    blocked = result.with(finish_quality: "blocked", refusal_category: "SPII")
    assert_predicate blocked, :refused?, "a content block is a declined answer too"
    refute_predicate blocked, :truncated?
    refute_predicate inference_requests([[200, {}, contract.fetch("valid_truncated_fixture")]]).fetch("os-1").result, :refused?
  end

  # A DECLINED RUN THE CREATOR'S FALLBACK ANSWERED reads its latest
  # execution — the fallback's model and answer — and says what that
  # execution replaced; a run that never moved carries no switch.
  def test_a_switched_run_reads_the_fallback_and_what_it_replaced
    inference_request = inference_requests([[200, {}, contract.fetch("valid_switched_fixture")]]).fetch("os-1")
    switch = inference_request.result.model_change

    assert_equal ["dev", "fallback"], [inference_request.model.provider_id, inference_request.model.model_ref]
    assert_equal "completed", inference_request.result.status
    refute_predicate inference_request.result, :refused?
    assert_equal ["dev/primary", "dev/fallback", "model_refused", "cyber"],
      [switch.from, switch.to, switch.reason, switch.category]
    assert_equal({ from: "dev/primary", to: "dev/fallback", reason: "model_refused",
                   category: "cyber" }, inference_request.result.to_h.fetch(:model_change))
    assert_nil inference_requests([[200, {}, contract.fetch("valid_fixture")]]).fetch("os-1").result.model_change
  end

  def test_a_failed_run_carries_its_code_and_no_answer
    result = inference_requests([[200, {}, contract.fetch("valid_failed_fixture")]]).fetch("os-1").result

    assert_predicate result, :failed?
    refute_predicate result, :truncated?
    assert_equal "provider_error", result.error.code
    assert_nil result.output_text
    refute result.error.attempt_budget_spent,
      "the caveat is present only when it applies; an ordinary failure carries none"
  end

  # THE TYPED NON-TEXT RESULT (C-U2): an embedding run answers vectors, not
  # a JSON document in the prose slot — `embeddings` is `[Embedding(index,
  # vector)]`, `output_text` is nil there, and a workload that produces no
  # vectors reads nil rather than an empty list.
  def test_an_embedding_run_answers_its_vectors_typed_and_no_output_text
    result = inference_requests([[200, {}, contract.fetch("valid_embedding_fixture")]]).fetch("os-embed").result

    assert_equal "completed", result.status
    assert_nil result.output_text
    embedding = result.embeddings.fetch(0)
    assert_instance_of CybrosAgent::Api::InferenceRequestEmbedding, embedding
    assert_equal 0, embedding.index
    assert_equal [0.1, 0.2, 0.3], embedding.vector
    assert_equal [[0.1, 0.2, 0.3]], result.vectors
    assert_equal({ index: 0, vector: [0.1, 0.2, 0.3] }, result.to_h.fetch(:embeddings).fetch(0))

    text = inference_requests([[200, {}, contract.fetch("valid_fixture")]]).fetch("os-1").result
    assert_nil text.embeddings
    assert_equal [], text.vectors, "iterating is safe on a workload that produced none"
    refute text.to_h.key?(:embeddings)
  end

  def test_result_to_h_serializes_the_complete_typed_projection_deeply
    image = inference_requests([[200, {}, contract.fetch("valid_image_fixture")]]).fetch("os-image").result.to_h
    file = image.fetch(:output_files).fetch(0)
    usage = image.fetch(:usage)

    assert_equal %i[byte_size content_type filename index], file.keys.sort
    assert_equal "image/png", file.fetch(:content_type)
    assert usage.key?(:usage_record_public_id)
    assert usage.key?(:cost_complete)
    refute_includes usage.values, nil, "compacted optional counters do not leak as null members"

    failed = inference_requests([[200, {}, contract.fetch("valid_failed_fixture")]])
      .fetch("os-failed").result.to_h
    assert_equal({ code: "provider_error", attempt_budget_spent: false }, failed.fetch(:error))
    refute failed.key?(:output_text), "an absent terminal field stays absent in the serialized projection"
  end

  # TWO ANSWERS A FAILED TURN HAS TO TELL APART: "retry later" and "fix your
  # request". When this side's retry budget is what ended the run, `code` still
  # names what the provider said on the last attempt — otherwise the caller
  # learns only that we stopped — and the budget rides beside it.
  def test_a_run_the_retry_budget_ended_still_names_what_the_provider_said
    result = inference_requests([[200, {}, contract.fetch("valid_budget_spent_fixture")]]).fetch("os-1").result

    assert_predicate result, :failed?
    assert_equal "provider_http_error", result.error.code
    assert result.error.attempt_budget_spent
  end

  # A run the provider was overloaded for on every attempt names the overload
  # as its code, the spent budget beside it — the same shape, a new word.
  def test_an_overloaded_run_names_the_overload_beside_the_spent_budget
    result = inference_requests([[200, {}, contract.fetch("valid_overloaded_fixture")]]).fetch("os-1").result

    assert_predicate result, :failed?
    assert_equal "provider_overloaded", result.error.code
    assert result.error.attempt_budget_spent
  end

  # THE COMPACTED ENVELOPE. Every counter is a provider's choice to report, so
  # a receipt that names only what the pack calls required must still parse —
  # and each unreported counter must arrive as nil rather than as a zero the
  # SDK invented.
  def test_usage_parses_when_only_the_required_members_are_present
    minimal = contract.fetch("usage_projection_required")
      .to_h { |key| [key, contract.dig("valid_fixture", "inference_request", "result", "usage", key)] }
    fixture = contract.fetch("valid_fixture")
    body = { "inference_request" => fixture.fetch("inference_request").merge(
      "result" => fixture.dig("inference_request", "result").except("timing").merge("usage" => minimal)
    ) }

    result = inference_requests([[200, {}, body]]).fetch("os-1").result

    assert_equal minimal.fetch("usage_record_public_id"), result.usage.usage_record_public_id
    assert_nil result.usage.total_tokens, "an unreported counter is nil, never a zero"
    assert_nil result.timing, "timing compacts away entirely when nothing was measured"
  end

  # MONEY IS A STRING. The server sends the digits it stored, and turning them
  # into a Float here would be the one place the amount could change.
  def test_the_cost_amount_stays_a_decimal_string
    usage = inference_requests([[200, {}, contract.fetch("valid_fixture")]]).fetch("os-1").result.usage

    assert_instance_of String, usage.cost_amount
    assert_equal contract.dig("valid_fixture", "inference_request", "result", "usage", "cost_amount"),
      usage.cost_amount
  end

  def test_a_counter_of_the_wrong_type_is_a_malformed_response
    fixture = contract.fetch("valid_fixture")
    body = { "inference_request" => fixture.fetch("inference_request").merge(
      "result" => fixture.dig("inference_request", "result").merge(
        "usage" => fixture.dig("inference_request", "result", "usage").merge("total_tokens" => "1264")
      )
    ) }

    assert_raises(CybrosAgent::Api::MalformedResponse) { inference_requests([[200, {}, body]]).fetch("os-1") }
  end

  # The summary is the exception that proves the rule: its counters default to
  # zero on the server, so they are read strictly and only the ratio is
  # optional. A queued run reports zero requests, which is a true statement.
  def test_the_usage_summary_is_always_present_and_counts_from_zero
    summary = inference_requests([[200, {}, contract.fetch("valid_queued_fixture")]]).fetch("os-1").usage_summary

    assert_equal 0, summary.request_count
    assert_nil summary.cache_hit_rate, "no input means no ratio to take"
    assert_equal "0.0", summary.cost_amount
  end

  def test_list_filters_by_workload_and_pages_by_cursor
    page = inference_requests([[200, {}, contract.fetch("valid_list_fixture")]])
      .list(workload: "embedding", after: "cursor-0", limit: 10)

    assert_equal :get, request.fetch(:method)
    assert_equal PATH, request.fetch(:path)
    assert_equal({ "workload" => "embedding", "after" => "cursor-0", "limit" => 10 },
      request.fetch(:params))
    summary = page.items.fetch(0)
    assert_instance_of CybrosAgent::Api::InferenceRequestSummary, summary
    refute_respond_to summary, :result,
      "the list projection carries no result, so it cannot answer terminality"
    refute_respond_to summary, :finished?
  end

  def test_events_read_the_replay_window_after_a_cursor
    page = inference_requests([[200, {}, contract.fetch("valid_events_fixture")]])
      .events("os-1", after: "cursor-0", limit: 50)

    assert_equal "#{PATH}/os-1/events", request.fetch(:path)
    assert_equal({ "after" => "cursor-0", "limit" => 50 }, request.fetch(:params))
    event = page.items.fetch(0)
    assert_equal contract.dig("valid_event_fixture", "type"), event.type
    assert_equal contract.dig("valid_event_fixture", "sequence"), event.sequence,
      "the ordered value a follower merges by is the sequence, not the opaque cursor"
    assert_equal "inference_request", event.resource_type
    assert_equal contract.dig("valid_event_fixture", "payload"), event.payload
    assert_equal page.next_after, contract.dig("valid_events_fixture", "pagination", "next_after")

    # THE HEAD, WHICH `next_after` IS NOT. It says where the STREAM was when
    # the page was served, which is what lets a follower stop draining a run
    # that is still producing.
    head = contract.dig("valid_events_fixture", "pagination", "watermark")
    assert_equal head, page.watermark
    assert page.caught_up?(head)
    refute page.caught_up?(head - 1), "one item short of the head is not caught up"
  end

  def test_an_event_type_this_gem_predates_is_carried_with_its_payload
    body = {
      "events" => [contract.fetch("unknown_event_type_fixture")],
      "pagination" => { "next_after" => nil, "watermark" => 1 },
    }
    event = inference_requests([[200, {}, body]]).events("os-1").items.fetch(0)

    assert_equal CybrosAgentTest::ContractFixtures.pack("meta.json").fetch("unknown_value_fixture"),
      event.type
    refute_empty event.payload, "an unrecognized type still delivers its payload intact"
  end

  # The payload is a snapshot, so a caller cannot mutate a held event into
  # disagreeing with what the server said.
  def test_an_event_payload_is_frozen
    event = inference_requests([[200, {}, contract.fetch("valid_events_fixture")]]).events("os-1").items.fetch(0)

    assert_predicate event.payload, :frozen?
    assert_raises(FrozenError) { event.payload["text"] = "tampered" }
  end

  def test_cancel_is_a_named_command_answering_the_standing_state
    inference_request = inference_requests([[200, {}, contract.fetch("valid_fixture")]]).cancel("os-1")

    assert_equal :post, request.fetch(:method)
    assert_equal "#{PATH}/os-1/cancellation", request.fetch(:path)
    assert_equal contract.dig("valid_fixture", "inference_request", "status"), inference_request.status
  end

  # Delete is the tombstone, not the cancel: running work refuses with a
  # Conflict the caller is meant to see rather than a silent cancellation.
  def test_delete_is_the_familys_one_empty_answer_and_refuses_running_work
    assert_nil inference_requests([[204, {}, nil]]).delete("os-1")
    assert_equal :delete, request.fetch(:method)
    assert_equal "#{PATH}/os-1", request.fetch(:path)

    refusal = contract.fetch("valid_error_fixture")
    error = assert_raises(CybrosAgent::Api::Conflict) do
      inference_requests([[refusal.fetch("status"), {}, refusal.fetch("body")]]).delete("os-2")
    end
    assert_equal "not_terminal", error.code
  end

  # The refusal vocabulary is OPEN — the server renders the domain's own
  # symbol as the code — so a code this gem predates must still arrive intact
  # on the exception rather than be flattened into a generic message.
  def test_a_refusal_code_this_gem_predates_reaches_the_caller
    unknown = contract.fetch("unknown_refusal_fixture")
    error = assert_raises(CybrosAgent::Api::InvalidRequest) do
      inference_requests([[unknown.fetch("status"), {}, unknown.fetch("body")]])
        .create(workload: "text_generation", model: "dev/text", input: "hi",
                idempotency_key: "key-1")
    end

    assert_equal contract.fetch("refusal_error_status"), 422
    assert_equal CybrosAgentTest::ContractFixtures.pack("meta.json").fetch("unknown_value_fixture"),
      error.code
  end

  # THE FILES A NON-TEXT WORKLOAD PRODUCED. The wire omits the member entirely
  # when there are none, and `files` is the one shape a caller iterates either
  # way — that asymmetry is the whole reason the reader exists.
  def test_output_files_are_typed_and_absent_means_empty
    image = inference_requests([[200, {}, contract.fetch("valid_image_fixture")]]).fetch("os-1")
    text = inference_requests([[200, {}, contract.fetch("valid_fixture")]]).fetch("os-1")

    file = image.result.files.fetch(0)
    assert_instance_of CybrosAgent::Api::InferenceRequestFile, file
    expected = contract.dig("valid_image_fixture", "inference_request", "result", "output_files", 0)
    assert_equal contract.fetch("output_file_projection").sort, file.members.map(&:to_s).sort
    assert_equal expected.fetch("index"), file.index
    assert_equal expected.fetch("content_type"), file.content_type
    assert_equal expected.fetch("byte_size"), file.byte_size

    assert_nil text.result.output_files, "the wire said nothing, so the member is nothing"
    assert_empty text.result.files, "and a caller can still iterate without asking first"
  end

  # A DOWNLOAD IS BYTES, NOT STRUCTURE. The transport parses JSON for every
  # other read; running that over a PNG yields nil, which is indistinguishable
  # from an empty answer — so the request states what it will accept.
  def test_download_asks_for_bytes_and_returns_them_verbatim
    png = "\x89PNG\r\n\x1a\n binary".b
    bytes = inference_requests([[200, {}, png]]).download("os-1", 1)

    assert_equal "#{PATH}/os-1/files/1", request.fetch(:path)
    assert_equal CybrosAgent::ANY_MEDIA, request.fetch(:accept),
      "a JSON Accept header is how a file comes back as nil"
    assert_equal png, bytes
    assert_equal Encoding::BINARY, bytes.encoding
  end

  def test_a_missing_file_is_the_familys_ordinary_not_found
    assert_raises(CybrosAgent::Api::NotFound) do
      inference_requests([[404, {}, { "error" => { "code" => "not_found" } }]]).download("os-1", 9)
    end
  end

  # THE FEED IS WIRED, not merely available: `after:` has to carry the pump's
  # cursor or every pass re-reads the same page.
  def test_feed_pages_the_events_endpoint_from_its_own_position
    first = contract.fetch("valid_event_fixture")
    second = first.merge("sequence" => 5, "cursor" => "cursor-5",
                         "public_id" => "01900000-0000-7000-8000-000000000063")
    # A head BEYOND this page is what makes the pump come back for more; a
    # page whose last item is the head is drained in one pass.
    page_one = { "events" => [first], "pagination" => { "next_after" => first.fetch("cursor"), "watermark" => 5 } }
    page_two = { "events" => [second], "pagination" => { "next_after" => "cursor-5", "watermark" => 5 } }
    lane = inference_requests([[200, {}, page_one], [200, {}, page_two]])

    seen = []
    lane.feed("os-1", limit: 50).each { |item| seen << item.sequence }

    assert_equal [first.fetch("sequence"), 5], seen
    assert_equal "#{PATH}/os-1/events", request.fetch(:path)
    assert_equal({ "limit" => 50 }, request.fetch(:params))
    assert_equal({ "after" => first.fetch("cursor"), "limit" => 50 },
      @transport.requests.fetch(1).fetch(:params),
      "the second pass resumes from the item the first one applied")
  end

  def test_ids_are_percent_encoded_into_one_path_segment
    inference_requests([[200, {}, contract.fetch("valid_fixture")]]).fetch("../../profile")

    assert_equal "#{PATH}/..%2F..%2Fprofile", request.fetch(:path)
  end
end
