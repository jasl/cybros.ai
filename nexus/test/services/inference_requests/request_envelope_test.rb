require "test_helper"

# The request-digest envelope is the identity of an accepted create. Its byte
# representation includes execution policy so a retry cannot change accepted
# constraints while replaying the original receipt.
class InferenceRequests::RequestEnvelopeTest < ActiveSupport::TestCase
  SELECTION = { "model_public_id" => "019fbe00-0000-7000-8000-000000000001" }.freeze
  INPUT = [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "hi" }] }].freeze

  def build(**overrides)
    InferenceRequests::RequestEnvelope.build(
      **{
        workload: "text_generation", model_selection: SELECTION, configuration: {}, input: INPUT,
        upload_public_ids: [],
      }.merge(overrides)
    )
  end

  def digest(result) = result.request_digest

  test "the envelope includes the complete submitted request and recovery policy" do
    result = build

    assert_predicate result, :accepted?
    assert_equal %w[billing_subject configuration fallback_models input model_selection selection_intent upload_public_ids],
      result.envelope.keys.sort
  end

  # Omission and explicit null are different bytes and therefore different
  # commands. The member's explicit null pins the absence of attribution.
  test "an absent billing subject is emitted as an explicit null, never omitted" do
    encoded = Nexus::CanonicalJson.encode(build.envelope)

    assert_includes encoded, %("billing_subject":null)
    assert_not_equal InferenceRequestCreateReceipt.digest_for(
      workload: "text_generation", envelope: build.envelope.except("billing_subject")
    ), digest(build)
  end

  test "absent, null, and blank billing subjects are one command" do
    baseline = digest(build)

    assert_equal baseline, digest(build(billing_subject: nil))
    assert_equal baseline, digest(build(billing_subject: ""))
    assert_equal baseline, digest(build(billing_subject: "   "))
  end

  # Blank attribution and a named billing subject have different identities.
  test "a nonblank billing subject is normalized into the frozen member" do
    result = build(billing_subject: "  acct_123  ")

    assert_predicate result, :accepted?
    assert_equal "acct_123", result.envelope.fetch("billing_subject")
    # One key, one digest — the normalization is the digest's, not a
    # caller's spelling.
    assert_equal digest(build(billing_subject: "acct_123")), digest(result)
    assert_not_equal digest(build), digest(result)
  end

  test "a billing subject key too long to store is refused, not raised" do
    result = build(billing_subject: "x" * (BillingSubject::KEY_MAX_LENGTH + 1))

    assert_not_predicate result, :accepted?
    assert_equal InferenceRequests::RequestEnvelope::BILLING_SUBJECT_TOO_LONG, result.refusal
    assert_nil result.envelope
  end

  # jsonb may expand an exponent-form number into a radically larger decoded
  # value, so canonical JSON refuses to carry one. That is the caller's data
  # rather than a code-level mistake, and the digest is taken before the
  # grammar ever sees the configuration — so this boundary is the only one
  # that can turn it into an answer instead of a server fault.
  test "a number canonical JSON cannot carry is refused, not raised" do
    result = build(configuration: { "temperature" => 1e-20 })

    assert_not_predicate result, :accepted?
    assert_equal InferenceRequests::RequestEnvelope::UNSUPPORTED_NUMBER, result.refusal
    assert_nil result.request_digest
  end

  test "text canonical JSON cannot store is refused, not raised" do
    result = build(input: "a\u0000b")

    assert_not_predicate result, :accepted?
    assert_equal InferenceRequests::RequestEnvelope::UNSUPPORTED_TEXT, result.refusal
    assert_nil result.request_digest
  end

  # The magnitudes that do render plainly are ordinary commands.
  test "an ordinary decimal is carried unchanged" do
    assert_predicate build(configuration: { "temperature" => 1.0e-7 }), :accepted?
  end

  # UUID spelling was already normalized at the Create boundary. This layer
  # preserves only the remaining semantic fact: submitted order.
  test "normalized upload order is semantic" do
    first = "019fbe00-0000-7000-8000-00000000000a"
    second = "019fbe00-0000-7000-8000-00000000000b"

    assert_not_equal digest(build(upload_public_ids: [first, second])),
      digest(build(upload_public_ids: [second, first]))
    assert_equal [first, second], build(upload_public_ids: [first, second])
      .envelope.fetch("upload_public_ids")
  end

  # The envelope is built from the already-coerced command, so the typed value
  # and the wire form it came from are the same command.
  test "a coerced message digests as the wire form it came from" do
    typed = [
      Nexus::TextInputMessage.new(
        role: "user", parts: [Nexus::TextInputPart.new(type: "text", text: "hi")]
      ),
    ]

    assert_equal digest(build), digest(build(input: typed))
  end

  test "the digest is stable across key insertion order" do
    reordered = InferenceRequests::RequestEnvelope.build(
      workload: "text_generation", upload_public_ids: [], input: INPUT,
      configuration: {}, model_selection: SELECTION
    )

    assert_equal digest(build), digest(reordered)
  end

  # The byte pin. If this changes, every live receipt's digest changed with
  # it, so the constant is the contract and not a snapshot to refresh.
  test "the frozen envelope digests to its pinned bytes" do
    result = build(configuration: { "temperature" => 0.5 }, upload_public_ids: [])

    assert_equal(
      '{"billing_subject":null,"configuration":{"temperature":0.5},' \
      '"fallback_models":null,' \
      '"input":[{"parts":[{"text":"hi","type":"text"}],"role":"user"}],' \
      '"model_selection":{"model_public_id":"019fbe00-0000-7000-8000-000000000001"},' \
      '"selection_intent":null,"upload_public_ids":[]}',
      Nexus::CanonicalJson.encode(result.envelope)
    )
    # SHA-256 of the outer canonical object, computed outside this codebase:
    # {"envelope":<the bytes above>,"workload":"text_generation"}
    assert_equal "ac339346724dca81eef6a78e1024b04d86820d8f252afeea383a9369d650221e",
      digest(result)
  end

  test "the workload is part of the digested identity, not of the envelope" do
    assert_not_equal digest(build(workload: "embedding")), digest(build)
  end
end
