require "test_helper"

# The complete input half of the workload contract: one selected candidate plus raw domain input
# becomes one normalized value, or is refused before M3 can persist a different interpretation.
class ModelSelection::WorkloadInputsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @member = users(:member)
  end

  test "text accepts scalar text or closed ordered message and part values" do
    messages = [
      text_message("system", "Follow the contract"),
      text_message("user", "First", "Second"),
    ]

    scalar = normalize(workload: "text_generation", input: "hello")
    structured = normalize(workload: "text_generation", input: messages)

    assert_predicate scalar, :accepted?
    assert_equal "hello", scalar.value.value
    assert_predicate structured, :accepted?
    assert_equal messages, structured.value.value
    assert_equal %w[system user], structured.value.value.map(&:role)
    assert_equal %w[First Second], structured.value.value.last.parts.map(&:text)
  end

  test "text rejects open hashes, string arrays, invalid roles, and invalid parts" do
    inputs = [
      [{ role: "user", content: "hello" }],
      ["first", "second"],
      [text_message("tool", "result")],
      [Nexus::TextInputMessage.new(role: "user", parts: [])],
      [text_message("user", " ")],
    ]

    inputs.each do |input|
      assert_equal :invalid_input,
        normalize(workload: "text_generation", input: input).refusal
    end
  end

  test "embedding normalizes scalar and ordered strings to one ordered batch" do
    scalar = normalize(workload: "embedding", input: "alpha")
    batch = normalize(workload: "embedding", input: ["alpha", "beta"])

    assert_equal ["alpha"], scalar.value.value
    assert_equal ["alpha", "beta"], batch.value.value
    assert_equal :invalid_input,
      normalize(workload: "embedding", input: ["valid", " "]).refusal
    assert_equal :missing_input,
      normalize(workload: "embedding", input: nil).refusal
  end

  # A five-text embedding on gemini's singular `embedContent` route was
  # accepted, stored, and then refused at seal — work told yes that could
  # never run, which is the shape this checkpoint fixed twice elsewhere. The
  # route's arity is a lane fact and acceptance is where the caller can still
  # act on it.
  test "a singular embedding route refuses a batch where the caller can fix it" do
    selection = embedding_selection("gemini_embeddings")

    assert_predicate normalize(workload: "embedding", input: "alpha", selection: selection),
      :accepted?
    assert_equal ModelSelection::Workloads::TOO_MANY_INPUT_TEXTS,
      normalize(workload: "embedding", input: %w[alpha beta], selection: selection).refusal
  end

  test "a lane that declares no arity carries whatever the batch bound allows" do
    selection = embedding_selection("openai_embeddings")

    assert_predicate normalize(workload: "embedding", input: %w[alpha beta], selection: selection),
      :accepted?
  end

  test "image and speech require one nonblank string" do
    %w[image_generation speech_generation].each do |workload|
      assert_predicate normalize(workload: workload, input: "content"), :accepted?
      assert_equal :missing_input, normalize(workload: workload, input: " ").refusal
      assert_equal :invalid_input, normalize(workload: workload, input: ["content"]).refusal
    end
  end

  test "selected candidate input-byte limits reject before persistence" do
    at_bound = normalize(workload: "image_generation", input: "a" * 65_536)
    over_bound = normalize(workload: "image_generation", input: "a" * 65_537)

    assert_predicate at_bound, :accepted?
    assert_equal :input_over_model_limit, over_bound.refusal

    audio = upload(media_type: "audio/wav")
    selection = selection_with_input_byte_limit("transcription", audio.byte_size - 1)
    assert_equal :input_over_model_limit,
      normalize(
        workload: "transcription", input: nil, uploads: [audio], selection: selection
      ).refusal
  end

  test "transcription accepts no hint or one nonblank hint with exactly one audio upload" do
    audio = upload(media_type: "audio/wav")

    assert_predicate normalize(
      workload: "transcription", input: nil, uploads: [audio]
    ), :accepted?
    assert_predicate normalize(
      workload: "transcription", input: "Names: Cybros", uploads: [audio]
    ), :accepted?
    assert_equal :invalid_input,
      normalize(workload: "transcription", input: " ", uploads: [audio]).refusal
    assert_equal :invalid_input,
      normalize(workload: "transcription", input: ["hint"], uploads: [audio]).refusal
  end

  test "transcription lowers neither missing nor multiple inputs silently" do
    audio = upload(media_type: "audio/wav")

    assert_equal :missing_input_upload,
      normalize(workload: "transcription", input: nil, uploads: []).refusal
    assert_equal :too_many_input_uploads,
      normalize(
        workload: "transcription", input: nil,
        uploads: [audio, upload(media_type: "audio/wav")]
      ).refusal
    assert_equal :too_many_input_uploads,
      normalize(workload: "transcription", input: nil, uploads: [audio, audio]).refusal
    assert_equal :unsupported_input_media,
      normalize(
        workload: "transcription", input: nil,
        uploads: [upload(media_type: "text/plain")]
      ).refusal
    assert_equal :unsupported_input_media,
      normalize(
        workload: "transcription", input: nil,
        uploads: [upload(media_type: "audio/aac")]
      ).refusal
  end

  test "workloads with no upload input reject references" do
    audio = upload(media_type: "audio/wav")
    inputs = {
      "speech_generation" => "speak",
      "embedding" => "embed",
    }

    inputs.each do |workload, input|
      assert_equal :uploads_not_supported,
        normalize(workload: workload, input: input, uploads: [audio]).refusal
      assert_predicate normalize(workload: workload, input: input), :accepted?
    end
  end

  # AN IMAGE EDIT IS AN IMAGE UPLOAD ON THE IMAGE LANE (the alignment audit's
  # F23: images/edits takes the source images in). The policy is the same
  # optional one text carries: a row that declares an image input accepts
  # image bytes, a row silent on it refuses them as unsupported media —
  # never as "this workload takes no uploads".
  test "image generation takes image uploads only on a row that declares an image input" do
    image = upload(media_type: "image/png")
    audio = upload(media_type: "audio/wav")

    silent = DevModelLane.selection(workload: "image_generation")
    assert_predicate normalize(workload: "image_generation", input: "draw", selection: silent), :accepted?
    assert_equal :unsupported_input_media,
      normalize(workload: "image_generation", input: "draw", uploads: [image], selection: silent).refusal

    editing = image_editing_selection
    assert_predicate normalize(
      workload: "image_generation", input: "make it night", uploads: [image], selection: editing
    ), :accepted?
    assert_equal :unsupported_input_media,
      normalize(workload: "image_generation", input: "make it night", uploads: [audio], selection: editing).refusal
  end

  test "text accepts only the exact profile MIME allowlist" do
    image = upload(media_type: "image/png")
    file = upload(media_type: "application/pdf")
    unsupported_image = upload(media_type: "image/heic")
    selection = selection_with_input_media(
      { "image" => { "mime_allowlist" => %w[image/png image/jpeg] } }
    )

    assert_predicate normalize(
      workload: "text_generation", input: placed("describe", image), uploads: [image],
      selection: selection
    ), :accepted?
    [file, unsupported_image].each do |unsupported|
      assert_equal :unsupported_input_media,
        normalize(
          workload: "text_generation", input: placed("describe", unsupported), uploads: [unsupported],
          selection: selection
        ).refusal
    end
  end

  # A DECLARED `token_cost` IS NOT REQUIRED, and this test is the inverse of
  # the one it replaces. Acceptance used to refuse a token-limited lane whose
  # modality declared no cost, because the request writer's TERMINAL token
  # gate would have counted that media as zero. The course correction made
  # that gate advisory and deleted the writer that held it, and the count
  # never included media anyway — so the precondition was protecting nothing
  # while making a shipped lane's declared capability unreachable.
  #
  # `xai/grok-4.6` is that lane in the shipped catalog: `input_modalities:
  # [image]` on a 500k-token window, with no `token_cost` on its profile's
  # image facts. Every image request against it was refused here.
  test "a token-limited lane accepts media that declares no token cost" do
    image = upload(media_type: "image/png")
    uncosted = selection_with_input_media(
      { "image" => { "mime_allowlist" => ["image/png"] } }, bounded: false
    )

    assert_predicate normalize(
      workload: "text_generation", input: placed("describe", image), uploads: [image],
      selection: uncosted
    ), :accepted?
  end

  # A PASS-THROUGH LANE SENDS THE SOURCE BYTES, so the send's 8 MiB inline
  # bound is already knowable here — and between it and the 100 MiB upload
  # bound sat work that acceptance took, admission priced and spent a capacity
  # slot on, and the send then refused. Only the pass-through half is
  # closable: a resizing lane's prepared size is not knowable until the
  # variant exists.
  test "an oversize upload on a pass-through lane is refused at acceptance" do
    big = upload(media_type: "image/png", byte_size: 12.megabytes)
    pass_through = selection_with_input_media(
      { "image" => { "mime_allowlist" => ["image/png"] } }, bounded: false
    )

    assert_equal :input_media_too_large,
      normalize(
        workload: "text_generation", input: placed("describe", big), uploads: [big],
        selection: pass_through
      ).refusal
  end

  # A MULTIPART LANE IS NOT AN INLINE LANE. Transcription audio rides the
  # attachments slot the wire body omits, so it is never base64'd into a
  # request part and the inline bound has nothing to say about it — the send
  # path exempts the whole workload by name. The first version of the check
  # above kept its own opinion instead of asking, and refused every
  # transcription over 8 MiB: about fifty seconds of WAV, on both shipped
  # lanes, work the send would have taken happily.
  test "multipart audio is not held to the inline bound at acceptance" do
    big = upload(media_type: "audio/wav", byte_size: 12.megabytes)
    lane = DevModelLane.selection(workload: "transcription", account: @account)

    assert_predicate normalize(
      workload: "transcription", input: "a hint", uploads: [big], selection: lane
    ), :accepted?
  end

  # And a resizing lane is left alone: its reduction is what makes the send's
  # answer almost always yes, and refusing here would reject work that runs.
  test "an oversize upload on a resizing lane is left to the send" do
    big = upload(media_type: "image/png", byte_size: 12.megabytes)
    resizing = selection_with_input_media(
      { "image" => { "mime_allowlist" => ["image/png"], "max_dimension" => 1600 } },
      bounded: false
    )

    assert_predicate normalize(
      workload: "text_generation", input: placed("describe", big), uploads: [big],
      selection: resizing
    ), :accepted?
  end

  # The shipped lane the removed precondition was silently blocking. Pinned
  # against the real catalog rather than a hand-built selection, because the
  # defect was invisible to every hand-built one.
  test "the shipped xai image lane accepts an image" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "xai", expected_lock_version: nil
    )
    ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "xai", api_key: "xai-acceptance"
    )
    resolved = ModelSelection::Resolver.new.resolve(
      account: @account.reload, workload: "text_generation",
      submitted: Nexus::SubmittedModelSelection.new(model: "xai/grok-4.6", reasoning_effort: nil)
    )
    assert_predicate resolved, :resolved?, "refusal: #{resolved.refusal.inspect}"
    assert_not_nil resolved.selection.capabilities.limits.input_token_bound,
      "the point of this lane is that it IS token-limited"

    facts = resolved.selection.execution_profile.input_media.fetch("image")
    assert_nil facts.token_cost,
      "no token cost is declared: that would be a claim about xAI's accounting, and the shared " \
      "figure comes from OpenAI's patch math"
    assert_equal SimpleInference::ApiFormat.defaults("xai_responses")[:input_media]
      .fetch("image").fetch("max_dimension"),
      facts.max_dimension,
      "but a platform cap IS declared — the largest image this platform will send, which is ours " \
      "to decide whatever the provider charges. Without it this lane passed source bytes to the " \
      "wire, alone among the shipped image profiles."

    image = upload(media_type: "image/png")

    assert_predicate normalize(
      workload: "text_generation", input: placed("describe", image), uploads: [image],
      selection: resolved.selection
    ), :accepted?
  end

  # And it stops being the pass-through lane, so a large image now RUNS
  # (reduced at send) instead of being refused at acceptance. That is the
  # better end of the trade the byte bound makes.
  test "the xai lane resizes rather than refusing a large image" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "xai", expected_lock_version: nil
    )
    ModelProviders::SetAPIKey.call(
      account: @account, provider_id: "xai", api_key: "xai-acceptance"
    )
    resolved = ModelSelection::Resolver.new.resolve(
      account: @account.reload, workload: "text_generation",
      submitted: Nexus::SubmittedModelSelection.new(model: "xai/grok-4.6", reasoning_effort: nil)
    )
    big = upload(media_type: "image/png", byte_size: 12.megabytes)

    assert_predicate normalize(
      workload: "text_generation", input: placed("describe", big), uploads: [big],
      selection: resolved.selection
    ), :accepted?
  end

  # The global role vocabulary is the UNION of every lane's, so a role a
  # lane's wire does not accept is refused here, where the caller can still
  # fix it, never at the wire. No shipped wire is narrower than the global
  # vocabulary any more — a `developer` turn rides every lane (the Anthropic
  # and Gemini wires lower it to `user` in place; the OpenAI-shaped wires
  # carry it) — so the refusal is pinned against a wire declaring a
  # narrower set.
  test "a role this lane's wire does not accept is refused at acceptance" do
    developer = [Nexus::TextInputMessage.from_h(
      "role" => "developer", "parts" => [{ "type" => "text", "text" => "be terse" }]
    )]
    anthropic = selection_for("anthropic_messages")

    SimpleInference::ApiFormat.stub(:accepted_roles, %w[system user assistant tool]) do
      assert_equal :unsupported_input_role,
        normalize(workload: "text_generation", input: developer, selection: anthropic).refusal
    end
  end

  # rho opens every conversation turn with a developer-role inline lead, and
  # the Anthropic and Gemini wires lower that role to `user` in place — yet
  # their ACCEPTED_ROLES omitted it, so this gate parked every rho
  # conversation on a direct Anthropic lane at turn 1 (the paid
  # live_cache_tier lane, 2026-09-18). The constants now tell what the
  # classes admit; this pins the agreement from the admission's side.
  test "a developer turn is admitted on every lane whose wire lowers or carries it" do
    developer = [Nexus::TextInputMessage.from_h(
      "role" => "developer", "parts" => [{ "type" => "text", "text" => "be terse" }]
    )]

    %w[anthropic_messages gemini_generate_content openai_responses].each do |format|
      assert_predicate normalize(
        workload: "text_generation", input: developer, selection: selection_for(format)
      ), :accepted?, "a developer turn must be admitted on #{format}"
    end
  end

  test "catalog modality narrowing cannot be widened by the exact profile" do
    image = upload(media_type: "image/png")
    base = selection_with_input_media(
      { "image" => { "mime_allowlist" => ["image/png"] } }
    )
    selection = base.with(
      capabilities: base.capabilities.with(input_modalities: ["text"])
    )

    assert_equal :unsupported_input_media,
      normalize(
        workload: "text_generation", input: "describe", uploads: [image], selection: selection
      ).refusal
  end

  test "a profile refuses media facts for a modality it does not declare" do
    assert_raises SimpleInference::ConfigurationError do
      selection_with_input_media(
        { "audio" => { "mime_allowlist" => ["audio/wav"] } }
      )
    end
  end

  test "text preserves duplicate upload positions and counts each toward the input byte limit" do
    image = upload(media_type: "image/png")
    prompt = placed("describe", image, image)
    uploads = [image, image]
    # The budget is the canonical bytes of the message stream itself plus each
    # binding's bytes, counted once per binding — so the exact boundary is
    # derived from the value under test rather than from the prompt text it
    # happens to contain.
    exact_limit =
      Nexus::CanonicalJson.bytesize(prompt.map(&:to_h)) + (image.byte_size * 2)

    accepted = normalize(
      workload: "text_generation", input: prompt, uploads: uploads,
      selection: selection_with_input_byte_limit("text_generation", exact_limit)
    )
    over_limit = normalize(
      workload: "text_generation", input: prompt, uploads: uploads,
      selection: selection_with_input_byte_limit("text_generation", exact_limit - 1)
    )

    assert_predicate accepted, :accepted?
    assert_equal [image.id, image.id], accepted.value.uploads.map(&:id)
    assert_equal :input_over_model_limit, over_limit.refusal
  end

  # The count refusal is storage's sanity bound, read from the registry
  # and never a ceiling of its own (Gate 3, 2026-09-10): a composed round
  # under the byte wall cannot reach it, so the only round it refuses is
  # one that alone exceeds the bound — the corruption case.
  test "the count refusal answers exactly past the registry's entry bound" do
    bound = Nexus::SizeBounds.fetch(:body_entry_count_bound)
    at_bound = Array.new(bound) { text_message("user", "x") }

    assert_nil ModelSelection::Workloads::Input.input_count_refusal(at_bound)
    assert_equal :content_items_too_many,
      ModelSelection::Workloads::Input.input_count_refusal(at_bound + [text_message("user", "x")])
  end

  private

    # A text-generation upload has a position only inside the ordered part stream, so every media
    # case states one. The alternative — a bare prompt whose uploads have no placement — is refused,
    # and these tests are about the allowlist and the byte budget, not about that.
    def placed(text, *uploads)
      parts = [Nexus::TextInputPart.new(type: "text", text: text)]
      uploads.each do |upload|
        parts << Nexus::UploadInputPart.new(type: "upload", upload_public_id: upload.public_id)
      end
      [Nexus::TextInputMessage.new(role: "user", parts: parts)]
    end

    def normalize(workload:, input:, uploads: [], selection: nil)
      ModelSelection::Workloads.normalize_workload_input(
        selection: selection || DevModelLane.selection(workload: workload),
        input: input,
        uploads: uploads
      )
    end

    def text_message(role, *texts)
      Nexus::TextInputMessage.new(
        role: role,
        parts: texts.map { |text| Nexus::TextInputPart.new(type: "text", text: text) }
      )
    end

    # `token_cost` rides along by default because a real declaration carries
    # it: the dev lane bounds input tokens, and a modality with no cost on a
    # bounded lane is refused on that ground alone — which is a different test.
    # The dev lane's shape with another lane's execution profile swapped in:
    # the acceptance gates read the profile, not the provider row.
    # The dev lane's text shape with another WIRE swapped in: the role gate
    # reads the adapter profile, which is what names the protocol class whose
    # accepted roles it asks for.
    def selection_for(format)
      selection = DevModelLane.selection(workload: "text_generation")
      profile = DevModelLane.profile_with(
        selection.execution_profile,
        profile_id: "probe/text@#{format}", adapter_profile: format
      )
      selection.with(execution_profile: profile)
    end

    # The dev lane's embedding shape with another lane's execution profile
    # swapped in: the arity gate reads the profile, not the provider row.
    def embedding_selection(format)
      selection = DevModelLane.selection(workload: "embedding")
      profile = DevModelLane.profile_with(
        selection.execution_profile,
        profile_id: "probe/embed@#{format}", adapter_profile: format
      )
      selection.with(execution_profile: profile)
    end

    # The image lane widened to take an image in, as an edits-capable row
    # would declare it: the modality on the capabilities and the profile,
    # the wire's own allowlist, no re-encode.
    def image_editing_selection
      selection = DevModelLane.selection(workload: "image_generation")
      profile = DevModelLane.profile_with(
        selection.execution_profile,
        input_modalities: ["image"],
        input_media: { "image" => { "mime_allowlist" => %w[image/png image/jpeg image/webp] } }
      )
      selection.with(
        execution_profile: profile,
        capabilities: selection.capabilities.with(input_modalities: ["image"])
      )
    end

    def selection_with_input_media(input_media, bounded: true)
      selection = DevModelLane.selection(workload: "text_generation")
      facts = input_media.transform_values do |values|
        bounded ? { "max_dimension" => 1_600, "token_cost" => 2_500 }.merge(values) : values
      end
      profile = DevModelLane.profile_with(selection.execution_profile, input_media: facts)
      selection.with(execution_profile: profile)
    end

    def selection_with_input_byte_limit(workload, limit)
      selection = DevModelLane.selection(workload: workload)
      capabilities = selection.capabilities.with(
        limits: selection.capabilities.limits.with(input_bytes: limit)
      )
      selection.with(capabilities: capabilities)
    end

    def upload(media_type: "audio/wav", byte_size: nil)
      bytes = "bytes-#{SecureRandom.hex(4)}"
      record = @account.content_uploads.create!(
        creating_user: @member,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "clip", content_type: media_type
        )
      )
      record.define_singleton_method(:byte_size) { byte_size } if byte_size
      record
    end
end
