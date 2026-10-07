require "test_helper"

# The InferenceRequest surface end to end through the public routes: receipt-
# idempotent async create, containment that conceals like absence, the
# typed refusal wire, the total cancel, and the replay window — with the
# execution underneath driven by the REAL chain against the fake adapter.
class AgentAPI::V1::InferenceRequestsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include InvocationHarness

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @token = create_access_token_fixture(user: @human, name: "Member")
    @workspace = workspaces(:shared)
  end

  test "create is 202 queued, replay is 200 same resource, mismatch is 409" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")

    assert_response :accepted
    body = response.parsed_body.fetch("inference_request")
    assert_equal "queued", body["status"]
    assert_equal "text_generation", body["workload"]
    assert_equal "dev", body.dig("model", "provider_id")
    public_id = body.fetch("public_id")

    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    assert_response :success
    assert_equal public_id, response.parsed_body.dig("inference_request", "public_id"),
      "exact replay returns the standing resource"
    assert_equal 1, InferenceRequest.where(workspace_id: @workspace.id).count

    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("something else")
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
  end

  test "a body missing its typed root is 400, never resurrected by wrapping" do
    post inference_requests_path, headers: auth("key-1"), as: :json,
      params: { workload: "text_generation", model: { model: "dev/mock-text" }, input: "hi" }

    assert_response :bad_request
    assert_equal 0, InferenceRequest.where(workspace_id: @workspace.id).count
  end

  test "a form-encoded create reads the same input the params boundary read" do
    post inference_requests_path, headers: auth("key-1"),
      params: { inference_request: { workload: "text_generation",
                            model: { model: "dev/mock-text" }, input: "say hi" } }

    assert_response :accepted,
      "one request, one parsed body: the escape hatch follows whatever Rails parsed"
  end

  test "a missing idempotency key is its own 400" do
    post inference_requests_path, headers: auth(nil), as: :json, params: payload("say hi")

    assert_response :bad_request
    assert_equal "idempotency_key_required", response.parsed_body.dig("error", "code")
  end

  test "a refusal crosses the wire typed, symbol for symbol" do
    post inference_requests_path, headers: auth("key-1"), as: :json,
      params: payload("say hi", model: "dev/no-such-model")

    assert_response :unprocessable_entity
    code = response.parsed_body.dig("error", "code")
    assert_not_equal "validation_failed", code, "the domain symbol, never a laundered generic"
    assert_match(/\A[a-z_]+\z/, code)
    assert_equal 0, InferenceRequest.where(workspace_id: @workspace.id).count
  end

  test "the public boundary normalizes a submitted model to a string" do
    submitted = nil
    refusal = InferenceRequests::Create::Result.refused(:invalid_model_selection)

    InferenceRequests::Create.stub(:call, ->(command:, port:) {
      submitted = command.submitted.model
      refusal
    }) do
      post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi", model: 123)
    end

    assert_response :unprocessable_entity
    assert_equal "123", submitted
    assert_equal "invalid_model_selection", response.parsed_body.dig("error", "code")
  end

  test "the same key with a different workload is a divergence, not a second create" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("embed me")
    assert_response :accepted

    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "embedding", model: { model: "dev/mock-embedding" },
                  input: "embed me" },
    }
    assert_response :conflict
    assert_equal "idempotency_envelope_mismatch", response.parsed_body.dig("error", "code")
    assert_equal 1, InferenceRequest.where(workspace_id: @workspace.id).count,
      "the digest arbitrates every payload dimension, workload included"
  end

  test "the wire shape is the documented key set, queued and terminal alike" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("tell me")
    body = response.parsed_body.fetch("inference_request")
    assert_equal %w[billing_subject created_at model public_id status updated_at
                    usage_summary workload],
      body.keys.sort
    assert_equal %w[model_ref provider_id reasoning_effort reasoning_enabled], body.fetch("model").keys.sort
    assert_nil body["result"], "no result envelope before terminality — presence IS the signal"
    assert_equal 0, body.dig("usage_summary", "request_count"),
      "the cumulative cache is always present — zero requests is a true statement"

    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{body.fetch("public_id")}", headers: auth
    full = response.parsed_body.fetch("inference_request")
    assert_equal %w[billing_subject created_at model public_id result status updated_at
                    usage_summary workload],
      full.keys.sort
    assert_equal 1, full.dig("usage_summary", "request_count"),
      "the one completed attempt is in the cumulative cache"
    result = full.fetch("result")
    assert_equal %w[output_text status timing usage], result.keys.sort,
      "error and reasoning compact away when absent; the rest is the contract"

    # THE CONTRACT PACK'S OWN PIN. Basic is generated from the presenter, so it
    # cannot drift; `usage_summary` and `result` are a query and an invocation
    # read, which the generator composes by hand — which is exactly the half
    # that could quietly stop matching. This is where the pack meets the wire.
    contract = Nexus::Contract.pack.fetch("inference_requests.json")
    assert_equal contract.fetch("queued_projection").sort, body.keys.sort
    assert_equal %w[result], full.keys - body.keys,
      "the pack's queued shape is the full one minus exactly the result envelope"
    assert_equal (contract.fetch("result_projection_required") + %w[output_text usage timing]).sort,
      result.keys.sort,
      "the clean text finish is the pack's required set plus the answer and its receipt exactly"
    assert_equal %w[output_text usage timing],
      %w[output_text usage timing] & contract.fetch("result_projection_optional"),
      "the answer and the receipt are named optional: image and embedding runs, and a run cut before" \
      " any attempt, omit them"
    # SUBSET AND SUPERSET, not equality: usage and timing compact every nil
    # away, so the pack names the widest shape and the members that survive it.
    assert_pack_shape(contract, "usage", result.fetch("usage").keys)
    assert_pack_shape(contract, "timing", result.fetch("timing").keys)
    assert_pack_shape(contract, "usage_summary", full.fetch("usage_summary").keys)
    assert_equal contract.fetch("model_projection").sort, body.fetch("model").keys.sort
  end

  test "the polling list is workspace-scoped, listable, and keyset-paginated" do
    target_ids = 3.times.map do |index|
      post inference_requests_path, headers: auth("poll-#{index}"), as: :json,
        params: payload("poll #{index}")
      assert_response :accepted
      response.parsed_body.dig("inference_request", "public_id")
    end
    tombstoned_id = target_ids.max
    InferenceRequest.find_by!(public_id: tombstoned_id).update_columns(tombstoned_at: Time.current)

    foreign = InferenceRequest.create!(
      workspace: workspaces(:personal), creating_user: users(:curator),
      workload: "text_generation"
    )
    DevModelLane.create_invocation!(inference_request: foreign)

    expected = (target_ids - [tombstoned_id]).sort
    get inference_requests_path, headers: auth, params: { limit: 1 }

    assert_response :success
    first_page = response.parsed_body
    assert_equal [expected.first], first_page.fetch("inference_requests").map { _1.fetch("public_id") }
    cursor = first_page.dig("pagination", "next_after")
    assert cursor.present?

    get inference_requests_path, headers: auth, params: { limit: 1, after: cursor }

    assert_response :success
    second_page = response.parsed_body
    assert_equal [expected.last], second_page.fetch("inference_requests").map { _1.fetch("public_id") }
    assert_nil second_page.dig("pagination", "next_after")
    returned = first_page.fetch("inference_requests") + second_page.fetch("inference_requests")
    returned_ids = returned.map { _1.fetch("public_id") }
    refute_includes returned_ids, tombstoned_id, "tombstones stay concealed from polling"
    refute_includes returned_ids, foreign.public_id,
      "a valid row from another Workspace never enters this polling feed"
  end

  # TERMINAL QUALITY on the wire (Round E): a cut-off answer reads as a
  # `completed` run whose caveat sits BESIDE the status — never inside
  # `error`, which is for runs that produced nothing — and the read surface
  # and the replay wake use the same vocabulary without duplicating the full
  # REST result.
  test "a truncated answer reads as completed with the caveat beside the status" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("write forever")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    fake_dispatch(sse_incomplete("as far as I got")) do
      perform_enqueued_jobs while enqueued_jobs.any?
    end

    get "#{inference_requests_path}/#{public_id}", headers: auth
    result = response.parsed_body.dig("inference_request", "result")
    assert_equal "completed", result.fetch("status")
    assert_equal "output_budget_exhausted", result.fetch("finish_quality")
    assert_nil result["error"], "a caveat is not an error"
    assert_equal "as far as I got", result.fetch("output_text"),
      "the partial answer is the answer, and it was billed"

    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    terminal = response.parsed_body.fetch("events").find { _1.fetch("type") == "result" }
    assert_equal "output_budget_exhausted", terminal.dig("payload", "result", "finish_quality"),
      "the bounded wake preserves the terminal caveat"

    contract = Nexus::Contract.pack.fetch("inference_requests.json")
    assert_equal contract.fetch("event_projection").sort, terminal.keys.sort
    assert_equal contract.dig("valid_truncated_fixture", "inference_request", "result").keys.sort,
      result.keys.sort, "the pack's truncated specimen is the shape a caveat really takes"
  end

  test "the replay result is a thin wake on a clean finish" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    terminal = response.parsed_body.fetch("events").find { _1.fetch("type") == "result" }
    assert_equal %w[inference_request_public_id status],
      terminal.fetch("payload").fetch("result").keys.sort,
      "usage, timing, output, and reasoning belong to the authoritative REST read"
  end

  # EVERY GENERATION PARAMETER THE CATALOG DECLARES, over the wire.
  #
  # This whole member used to 500. Strong Parameters hands the action an
  # `ActionController::Parameters`, which canonical JSON cannot encode, so the
  # envelope's own digest raised out of the controller — for temperature and
  # max_output_tokens and voice and dimensions and result_count alike. Nothing
  # caught it because every configuration test called `InferenceRequests::Create`
  # directly with a Ruby Hash, which is exactly the shape the wire never sends.
  test "a configuration sent over HTTP reaches the resolved model" do
    post inference_requests_path, headers: auth("key-1"), as: :json,
      params: payload("say hi").deep_merge(
        inference_request: { configuration: { temperature: 0.25, max_output_tokens: 64 } }
      )

    assert_response :accepted
    inference_request = InferenceRequest.find_by!(public_id: response.parsed_body.dig("inference_request", "public_id"))
    options = inference_request.model_invocation.request_options
    assert_equal 0.25, options.fetch("temperature")
    assert_equal 64, options.fetch("max_output_tokens")
  end

  # THE MEMBER THAT MAKES THE COERCION NON-OBVIOUS. A json_schema output format
  # is two grammars in one value: its own members are parameter NAMES the
  # grammar reads as Symbols, and the `schema` under them is OPAQUE JSON that
  # canonical JSON demands String keys of. Symbolizing the whole thing — the
  # one-line fix anyone would reach for — turns this into a silent 422.
  test "a json_schema output format survives the wire with its schema intact" do
    schema = { "type" => "object", "properties" => { "answer" => { "type" => "string" } } }
    post inference_requests_path, headers: auth("key-1"), as: :json,
      params: payload("say hi").deep_merge(
        inference_request: { configuration: { output_format: {
          type: "json_schema", name: "reply", strict: true, schema: schema,
        } } }
      )

    assert_response :accepted
    inference_request = InferenceRequest.find_by!(public_id: response.parsed_body.dig("inference_request", "public_id"))
    format = inference_request.model_invocation.request_options.fetch("output_format")
    assert_equal "json_schema", format.fetch("type")
    assert_equal "reply", format.fetch("name")
    assert_equal schema, format.fetch("schema"),
      "the schema is opaque JSON and must reach the model exactly as it was sent"
  end

  # PINNED BECAUSE IT IS DELIBERATELY AMBIGUOUS. `unsupported_workload` answers
  # both "there is no such workload" (a typo here) and "this model does not
  # serve that workload" (pick another model) — two remedies behind one word,
  # which is the shape of a defect. Two independent reviews nonetheless said
  # LEAVE IT: the second meaning is written into `failure_reason_key` on
  # durable rows and is the predecessor's own word for the same condition
  # (core_matrix admit_queued_work.rb:280), and every candidate split either
  # collides with a family code or enlarges a vocabulary the pack calls closed.
  # So the wire behaviour is pinned instead, and the next change to it has to
  # be deliberate rather than a side effect.
  test "an unknown workload name is refused as unsupported, not as a bad parameter" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "video_generation", model: { model: "dev/mock-text" },
                  input: "make a film" },
    }

    assert_response :unprocessable_entity
    assert_equal "unsupported_workload", response.parsed_body.dig("error", "code")
  end

  # THE ONE OPEN-VOCABULARY CODE THIS SURFACE ADVERTISES BY NAME, and nothing
  # asserted the string a caller actually receives — only the Ruby constant.
  # A code named on a resource page is a promise like any other.
  test "an over-long billing subject is refused by name" do
    post inference_requests_path, headers: auth("key-1"), as: :json,
      params: payload("say hi").deep_merge(inference_request: { billing_subject: "b" * 129 })

    assert_response :unprocessable_entity
    assert_equal "billing_subject_too_long", response.parsed_body.dig("error", "code")
  end

  # A MODEL THAT CANNOT TAKE THIS MUCH IS NOT A PAYLOAD THAT IS TOO LARGE. The
  # limit here is a per-model catalog capability — 64 KiB on this lane, and as
  # low as 2000 bytes on others — so answering `413 content_too_large` would
  # claim the server was unwilling to process a request it processes fine, and
  # would leave a caller unable to tell a prompt cap from a storage bound. This
  # surface had NO status assertion at all until now, which is how a change to
  # the family status mapping moved it from 422 to 413 unseen.
  test "an input over the model's own limit is a typed 422, not a payload refusal" do
    oversize = payload("a" * 65_537).deep_merge(
      inference_request: { workload: "image_generation", model: { model: "dev/mock-image" } }
    )

    post inference_requests_path, headers: auth("key-1"), as: :json, params: oversize
    assert_response :unprocessable_entity
    assert_equal "input_over_model_limit", response.parsed_body.dig("error", "code")

    # The estimate reaches the same refusal, and used to move with it. Its own
    # typed root, so the body is rebuilt rather than reused.
    post "#{inference_requests_path}/input_estimate", headers: auth, as: :json, params: {
      input_estimate: { workload: "image_generation",
                        model: { model: "dev/mock-image" }, input: "a" * 65_537 },
    }
    assert_response :unprocessable_entity
    assert_equal "input_over_model_limit", response.parsed_body.dig("error", "code")
  end

  test "an unknown generation parameter is still refused, over the wire too" do
    post inference_requests_path, headers: auth("key-1"), as: :json,
      params: payload("say hi").deep_merge(inference_request: { configuration: { nonesuch: 1 } })

    assert_response :unprocessable_entity
    assert_equal "unsupported_generation_parameter", response.parsed_body.dig("error", "code"),
      "coercion must not widen what the grammar accepts"
  end

  # THE SEQUENCE IS WHAT A FOLLOWER MERGES BY, so its two properties are pinned
  # here rather than left to be discovered: it is CONTIGUOUS from 1, and it is
  # the same number the opaque cursor wraps.
  #
  # The second half is the point of publishing it at all. If the two could
  # disagree there would be two truths on the wire, and a consumer would go
  # back to decoding the cursor — the hidden contract the predecessor's agent
  # had and this one is meant to retire.
  test "the replay stream publishes a contiguous sequence that agrees with its cursor" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    events = response.parsed_body.fetch("events")
    refute_empty events

    sequences = events.map { _1.fetch("sequence") }
    assert_equal (1..events.length).to_a, sequences,
      "a follower detects a gap by arithmetic, which only works if there are none to invent"
    events.each do |event|
      assert_equal event.fetch("sequence"),
        InferenceRequestEventItem::ReplayCursor.decode(event.fetch("cursor")),
        "the published sequence and the opaque cursor must not be two different truths"
    end
  end

  # THE WATERMARK IS WHERE THE STREAM IS, which is a different question from
  # where the page stopped — and it is the only one a follower draining a
  # still-producing stream can terminate on.
  test "the replay window names the head of the stream on every page, empty ones included" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    # BEFORE ANYTHING IS APPENDED. `next_after` has nothing to say and says
    # nothing; the watermark still answers, because "drained at zero" is a
    # true statement and a member that vanishes is one more branch for a
    # consumer that has no reason to care.
    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    pagination = response.parsed_body.fetch("pagination")
    assert_equal Nexus::Contract.pack.fetch("inference_requests.json").fetch("events_pagination").sort,
      pagination.keys.sort
    assert_nil pagination.fetch("next_after")
    assert_equal 0, pagination.fetch("watermark")

    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    head = response.parsed_body.fetch("events").last.fetch("sequence")
    assert_operator head, :>, 1, "this turn must produce several items or the next case proves nothing"

    # A PAGE THAT STOPS SHORT still names the head. This is the whole point:
    # a consumer paging through a stream knows how far it has to go before it
    # has caught up, rather than guessing from a page that came back short.
    get "#{inference_requests_path}/#{public_id}/events?limit=1", headers: auth
    page = response.parsed_body
    assert_equal 1, page.fetch("events").length
    pagination = page.fetch("pagination")
    assert_equal 1, InferenceRequestEventItem::ReplayCursor.decode(pagination.fetch("next_after")),
      "next_after names where this page stopped, and it stays an opaque cursor"
    assert_equal head, pagination.fetch("watermark"),
      "the watermark names where the STREAM is — a sequence, because it exists to be compared"
  end

  # THE BYTES A NON-TEXT WORKLOAD PRODUCED, and the one thing a completed image
  # turn could not give a caller until now.
  #
  # THE ORDER IS THE ASSERTION. `has_many_attached` emits no ORDER BY, so two
  # images is the smallest case where an unordered read can hand back the wrong
  # one — and the provider's own index survives only inside the blob filename,
  # which is the thing nobody should be parsing. The listing and the route must
  # agree on which file is index 0, or a caller downloads a file the listing
  # did not describe.
  test "a generated image is listed in order and streamed back through the API" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "image_generation", model: { model: "dev/mock-image" },
                  input: "draw two cats", configuration: { result_count: 2 } },
    }
    assert_response :accepted
    public_id = response.parsed_body.dig("inference_request", "public_id")

    fake_dispatch(json_response(200, {
      "created" => 0,
      "data" => [{ "b64_json" => [png_bytes].pack("m0") }, { "b64_json" => [second_image_bytes].pack("m0") }],
    })) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}", headers: auth
    files = response.parsed_body.dig("inference_request", "result", "output_files")
    assert_equal [0, 1], files.map { _1.fetch("index") }
    assert_equal %w[image/png image/png], files.map { _1.fetch("content_type") }
    contract = Nexus::Contract.pack.fetch("inference_requests.json")
    assert_equal contract.fetch("output_file_projection").sort, files.first.keys.sort

    get "#{inference_requests_path}/#{public_id}/files/0", headers: auth
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal png_bytes, response.body.b,
      "index 0 must be the first image the provider sent, not whichever row came back first"
    assert_equal files.first.fetch("byte_size"), response.body.b.bytesize

    get "#{inference_requests_path}/#{public_id}/files/1", headers: auth
    assert_equal second_image_bytes, response.body.b
  end

  # THE BYTES ARE SERVED THROUGH THE FRAMEWORK'S OWN STREAMING (rank 4):
  # `ActiveStorage::Streaming` answers a `Range` with a 206 and the slice,
  # and a whole read with `Accept-Ranges`, on whatever storage service the
  # deployment configured — the Disk-only file server is gone. `Streaming`
  # runs the body on a live thread, so this is also the pin that `Current`
  # (the credential) carries into it.
  test "a generated image is streamed with byte ranges through the framework's streaming" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "image_generation", model: { model: "dev/mock-image" }, input: "draw a cat" },
    }
    assert_response :accepted
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(json_response(200, {
      "created" => 0, "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
    })) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}/files/0", headers: auth
    assert_response :success
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_equal png_bytes.bytesize.to_s, response.headers["Content-Length"]
    assert_match(/\Aattachment;/, response.headers["Content-Disposition"])
    assert_equal png_bytes, response.body.b

    get "#{inference_requests_path}/#{public_id}/files/0", headers: auth.merge("Range" => "bytes=0-7")
    assert_response :partial_content
    assert_equal png_bytes.byteslice(0, 8), response.body.b, "the slice the range named"
    assert_equal "bytes 0-7/#{png_bytes.bytesize}", response.headers["Content-Range"]
    assert_equal "image/png", response.media_type
  end

  # THE TYPED NON-TEXT RESULT (C-U2): an embedding run's answer is vectors,
  # and the wire says so — `embeddings: [{index, vector}]` on the result,
  # and no `output_text` to parse a JSON document out of.
  test "an embedding run answers its vectors typed and carries no output_text" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "embedding", model: { model: "dev/mock-embedding" }, input: "embed me",
                  configuration: { dimensions: 3 } },
    }
    assert_response :accepted
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(json_response(200, {
      "object" => "list", "model" => "mock-embedding",
      "data" => [{ "object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2, 0.3] }],
      "usage" => { "prompt_tokens" => 2, "total_tokens" => 2 },
    })) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}", headers: auth
    result = response.parsed_body.dig("inference_request", "result")
    assert_equal "completed", result.fetch("status")
    assert_equal [{ "index" => 0, "vector" => [0.1, 0.2, 0.3] }], result.fetch("embeddings")
    refute result.key?("output_text"), "the vectors are the answer; there is no prose to render"
    contract = Nexus::Contract.pack.fetch("inference_requests.json")
    assert_includes contract.fetch("result_projection_optional"), "embeddings"
    assert_equal result.fetch("embeddings").first.keys.sort,
      contract.dig("valid_embedding_fixture", "inference_request", "result", "embeddings").first.keys.sort
  end

  test "a text run advertises no files, and its file route is absent rather than empty" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}", headers: auth
    assert_nil response.parsed_body.dig("inference_request", "result", "output_files"),
      "a workload that produces no files must not make every caller check an empty array"

    get "#{inference_requests_path}/#{public_id}/files/0", headers: auth
    assert_response :not_found
  end

  # THE FILE ROUTE IS THE ONE-SHOT'S, tier for tier. Active Storage's own blob
  # routes are public and permanent by design, which is exactly why nothing is
  # redirected there: containment has to hold for the bytes as it does for the
  # resource that made them.
  test "another workspace's caller cannot reach a file, and a bad ordinal is refused" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "image_generation", model: { model: "dev/mock-image" },
                  input: "draw a cat" },
    }
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(json_response(200, {
      "created" => 0, "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
    })) { perform_enqueued_jobs while enqueued_jobs.any? }

    # THE FILE IS ADDRESSED THROUGH ITS WORKSPACE, so a caller holding the
    # one-shot's id and a workspace it can genuinely reach still gets nothing.
    # That is the tier that keeps the bytes inside the containment the resource
    # is under — the one an Active Storage redirect would have stepped around.
    foreign = create_access_token_fixture(user: users(:curator), name: "F")
    elsewhere = "/agent_api/v1/workspaces/#{workspaces(:personal).public_id}/inference_requests"
    get "#{elsewhere}/#{public_id}/files/0",
      headers: { "Authorization" => "Bearer #{foreign.secret}" }
    assert_response :not_found, "a foreign InferenceRequest reads exactly like absence"

    get "#{inference_requests_path}/#{public_id}", headers: { "Authorization" => "Bearer #{foreign.secret}" }
    assert_response :success,
      "the same credential CAN read the shared workspace's one-shot — so the refusal above " \
      "is containment, not a credential that happens to be powerless"

    get "#{inference_requests_path}/#{public_id}/files/9", headers: auth
    assert_response :not_found
    get "#{inference_requests_path}/#{public_id}/files/-1", headers: auth
    assert_response :bad_request
  end

  # A RANGE IS THE CAPABILITY THIS ROUTE GAINED when it stopped handing out a
  # String of the whole blob: a caller can seek inside a long speech clip and
  # resume an interrupted download instead of taking all of it or none. The
  # 416 belongs to the same contract — an unsatisfiable range has to be
  # refused, not quietly widened back to the whole file, which is exactly what
  # the previous implementation would have done with the header.
  test "a file answers a byte range, refuses an unsatisfiable one, and names itself" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: {
      inference_request: { workload: "image_generation", model: { model: "dev/mock-image" },
                  input: "draw a cat" },
    }
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(json_response(200, {
      "created" => 0, "data" => [{ "b64_json" => [png_bytes].pack("m0") }],
    })) { perform_enqueued_jobs while enqueued_jobs.any? }

    get "#{inference_requests_path}/#{public_id}/files/0",
      headers: auth.merge("Range" => "bytes=0-9")
    assert_response :partial_content
    assert_equal "bytes 0-9/#{png_bytes.bytesize}", response.headers["content-range"]
    assert_equal png_bytes.byteslice(0, 10), response.body.b

    get "#{inference_requests_path}/#{public_id}/files/0",
      headers: auth.merge("Range" => "bytes=#{png_bytes.bytesize + 1}-")
    assert_response :range_not_satisfiable
    assert_nil response.headers["x-cascade"],
      "Rack::Files asks the next app to try; there is no next app, so the 416 is the answer"

    # THE DISPOSITION NAMES THE FILE THE LISTING DESCRIBES. Serving a path
    # rather than bytes means the filename is no longer a `send_data`
    # argument, so the two read surfaces have to be tied together explicitly:
    # a caller who saw a name in the projection must receive that name when
    # the bytes arrive.
    get "#{inference_requests_path}/#{public_id}", headers: auth
    listed = response.parsed_body.dig("inference_request", "result", "output_files").first

    get "#{inference_requests_path}/#{public_id}/files/0", headers: auth
    assert_response :success
    assert_equal ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename: listed.fetch("filename")
    ), response.headers["Content-Disposition"]
  end

  test "delete is terminal-only, concealing, and clock-starting (re-audit)" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    delete "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :conflict, "running work refuses; cleanup never cancels for the caller"
    assert_equal "not_terminal", response.parsed_body.dig("error", "code")

    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }

    delete "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :no_content
    assert_not_nil InferenceRequest.find_by(public_id: public_id).tombstoned_at,
      "the frozen 30-day reap clock started"

    get "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :not_found, "tombstoned reads as absence"
    delete "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :not_found, "a second DELETE is the 404 concealment already serves"
  end

  test "delete requires the write tier (re-audit)" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")
    fake_dispatch(sse_success("done")) { perform_enqueued_jobs while enqueued_jobs.any? }
    @workspace.update_columns(state: "archived", archived_at: Time.current)

    delete "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :forbidden
    assert_nil InferenceRequest.find_by(public_id: public_id).tombstoned_at,
      "browsable is the read tier; deleting needs the write tier"
  end

  test "an archived workspace refuses the write and keeps the read" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("say hi")
    assert_response :accepted
    @workspace.update_columns(state: "archived", archived_at: Time.current)

    get inference_requests_path, headers: auth
    assert_response :success, "archived stays browsable"

    post inference_requests_path, headers: auth("key-2"), as: :json, params: payload("more")
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code")
  end

  test "the whole story: create, execute, read the answer, replay the events" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("tell me")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    # Three generations of work drain here: admission, the run job, and the
    # events converger it wakes.
    fake_dispatch(sse_success("the answer")) do
      perform_enqueued_jobs while enqueued_jobs.any?
    end

    get "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :success
    body = response.parsed_body.fetch("inference_request")
    assert_equal "completed", body["status"]
    assert_equal "Mock: the answer", body.dig("result", "output_text")
    usage = body.dig("result", "usage")
    assert_equal 2, usage["input_tokens"]
    assert usage["cost_complete"]

    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    assert_response :success
    events = response.parsed_body.fetch("events")
    types = events.map { |event| event.fetch("type") }
    assert_includes types, "run_status"
    assert_includes types, "result"
    assert_equal "inference_request", events.first.dig("resource", "type")
    assert_equal public_id, events.first.dig("resource", "public_id")

    cursor = events.first.fetch("cursor")
    get "#{inference_requests_path}/#{public_id}/events", headers: auth, params: { after: cursor }
    assert_response :success
    assert_equal types.length - 1, response.parsed_body.fetch("events").length,
      "the cursor is strictly exclusive"
  end

  test "the replay window rejects an oversize limit and a malformed cursor" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    get "#{inference_requests_path}/#{public_id}/events", headers: auth, params: { limit: 201 }
    assert_response :bad_request

    get "#{inference_requests_path}/#{public_id}/events", headers: auth, params: { after: "garbage" }
    assert_response :bad_request
  end

  test "the cancel gate holds the write tier" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")
    @workspace.update_columns(state: "archived", archived_at: Time.current)

    post "#{inference_requests_path}/#{public_id}/cancellation", headers: auth
    assert_response :forbidden
    assert_equal "not_authorized", response.parsed_body.dig("error", "code"),
      "browsable is the read tier; stopping work needs the write tier"
  end

  test "cancel is a total command that converges and repeats harmlessly" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    post "#{inference_requests_path}/#{public_id}/cancellation", headers: auth
    assert_response :success
    assert_equal "canceled", response.parsed_body.dig("inference_request", "status")

    post "#{inference_requests_path}/#{public_id}/cancellation", headers: auth
    assert_response :success
    assert_equal "canceled", response.parsed_body.dig("inference_request", "status"),
      "terminal is terminal; the repeat changes nothing"

    # THE PACK'S FLOOR: no attempt ever started, so there is no receipt and
    # no answer — the result is exactly the members the pack calls required.
    get "#{inference_requests_path}/#{public_id}", headers: auth
    result = response.parsed_body.dig("inference_request", "result")
    contract = Nexus::Contract.pack.fetch("inference_requests.json")
    assert_equal contract.fetch("result_projection_required").sort, result.keys.sort,
      "a run cut before any attempt carries the required set and nothing else"
  end

  test "no access and tombstones conceal like absence" do
    post inference_requests_path, headers: auth("key-1"), as: :json, params: payload("hi")
    public_id = response.parsed_body.dig("inference_request", "public_id")

    InferenceRequest.find_by!(public_id: public_id).update_columns(tombstoned_at: Time.current)
    get "#{inference_requests_path}/#{public_id}", headers: auth
    assert_response :not_found
    get "#{inference_requests_path}/#{public_id}/events", headers: auth
    assert_response :not_found, "the replay window conceals a tombstone the same way"
    post "#{inference_requests_path}/#{public_id}/cancellation", headers: auth
    assert_response :not_found

    # Curator's private workspace: member's credential sees absence, not 403.
    get "/agent_api/v1/workspaces/#{workspaces(:personal).public_id}/inference_requests",
      headers: { "Authorization" => "Bearer #{@token.secret}" }
    assert_response :not_found
  end

  private

    # A compacted envelope has no single key set, so the pack pins two: the
    # widest one nothing may exceed, and the required one nothing may fall
    # below. Asserting both is what makes a renamed or dropped member fail.
    def assert_pack_shape(contract, name, keys)
      widest = contract.fetch("#{name}_projection")
      assert_empty keys - widest, "#{name} rendered members the pack does not name"
      assert_empty contract.fetch("#{name}_projection_required") - keys,
        "#{name} dropped a member the pack calls required"
    end

    def inference_requests_path
      "/agent_api/v1/workspaces/#{@workspace.public_id}/inference_requests"
    end

    # Distinguishable from `png_bytes` by content AND by length, so an
    # ordering assertion cannot pass by accident on two identical files.
    def second_image_bytes
      png_bytes + "second".b
    end

    def payload(input, model: "dev/mock-text")
      {
        inference_request: {
          workload: "text_generation",
          model: { model: model },
          input: input,
        },
      }
    end

    def auth(key = nil)
      headers = { "Authorization" => "Bearer #{@token.secret}" }
      headers["Idempotency-Key"] = key if key
      headers
    end
end
