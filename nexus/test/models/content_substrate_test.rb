require "test_helper"

# M1A's substrate, proven where it is reachable: fragments and uploads are ordinary rows. M1B
# activates the OneShot body branch, but its first production writer and reachable product
# ContentBody still wait for M3.
class ContentSubstrateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = accounts(:cybros)
  end

  def build_fragment(payload: { "text" => "hello" }, account: @account, **attributes)
    account.content_fragments.new(payload: payload, **attributes)
  end

  test "a fragment keeps its writer-supplied address and deduplicates inside one account" do
    address = Nexus::ContentAddress.for(
      account_id: @account.id, payload: { "text" => "hello" }
    )
    first = build_fragment(digest: address.digest)
    assert first.save

    assert_equal address.digest, first.digest

    duplicate = build_fragment(digest: address.digest)
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!
    end

    assert_raises ActiveRecord::ReadonlyAttributeError do
      first.update(payload: { "text" => "changed" })
    end
  end

  # The base table is owner-neutral and every activated branch is named here, so a third one cannot
  # join silently. An ownerless row is not a state to converge — it is invalid.
  #
  # `one_shot` is M3's product branch. `model_invocation` is checkpoint 2's:
  # its `request` role is sealed by the request-snapshot writer, `response`
  # and `reasoning` by terminal apply — a role with no writer is exactly
  # what this test exists to catch (`diagnostic_input` left with the
  # provider-test run, 2026-09-18).
  test "a body without an activated owner branch is invalid" do
    assert_not ContentBody.new(account: @account, role: "input").valid?
    assert_equal %i[one_shot model_invocation conversation_input conversation_turn_variant
                    agent_loop_node],
      ContentBody::OWNER_ROLES.keys,
      "each later owner adds its branch beside its own writer — the two " \
      "conversation owners joined with the Conversation round (2026-08-28), " \
      "the loop node with the Dynamic-DAG round's S1 (its prompt writer); a " \
      "standalone loop's steer is a hosted conversation_input"
    assert_equal %w[reasoning reasoning_trace request response tool_calls],
      ContentBody::OWNER_ROLES.fetch(:model_invocation).sort,
      "the invocation owns its assembled request, provider results, " \
      "the replay-provenance sidecar (cross-model reasoning stage 1, " \
      "2026-08-29), and the normalized calls a round made (S5a)"
    assert_equal %w[input], ContentBody::OWNER_ROLES.fetch(:one_shot),
      "the one_shot result/reasoning pair never got a writer and its design " \
      "settled on the invocation branch (re-audit trim)"
  end

  test "an invocation-owned body requires its invocation" do
    body = ContentBody.new(
      account: @account, role: "response"
    )

    assert_not body.valid?
    assert_includes body.errors.attribute_names, :base
  end

  # The other half of "exactly one activated shape", which only became
  # reachable when a second branch existed: under checkpoint 1 there was no
  # other owner column to fill in, so the discriminator could not disagree
  # with the row.
  test "a body carrying the owner its discriminator does not name is invalid" do
    one_shot = create_one_shot
    invocation = DevModelLane.create_invocation!(one_shot: one_shot)
    body = ContentBody.new(
      account: @account, role: "input",
      one_shot: one_shot, model_invocation: invocation
    )

    assert_not body.valid?
    assert_includes body.errors.attribute_names, :base
  end

  # A seal carries no digest. One lived here for the compiled request body admission sealed, and a
  # digest earns its place only where it gates a decision — the course correction deleted both.
  test "a seal is a timestamp and carries no digest" do
    body = build_one_shot_body
    body.save!
    body.seal

    assert_predicate body.reload, :sealed?
    assert_not_includes ContentBody.column_names, "sealed_digest"
  end

  # A SEAL FREEZES THE BODY'S CONTENT, and until now it froze only the body's
  # own columns. Entries are individually immutable, but nothing stopped a new
  # one being inserted into a sealed body — the single guard lived in
  # `ContentBodies::Replace`, one service call away from any writer that
  # reached for `ContentBodyEntry` directly.
  #
  # A sealed request records the exact bytes sent to a provider. Appending an entry afterward would
  # make that record describe bytes never sent, so all entry writers must respect the seal.
  test "a sealed body refuses a new entry, not only a changed one" do
    body = build_one_shot_body
    body.save!
    payload = { "text" => "one" }
    fragment = ContentFragment.create!(
      account: @account, payload: payload, digest: Nexus::CanonicalJson.digest(payload)
    )
    ContentBodyEntry.create!(
      account: @account, content_body: body, content_fragment: fragment, position: 0
    )
    body.seal

    appended = ContentBodyEntry.new(
      account: @account, content_body: body.reload, content_fragment: fragment, position: 1
    )

    assert_not appended.valid?
    assert_includes appended.errors[:content_body], "is sealed"
  end

  test "a body does not carry unused display or locking mirrors" do
    assert_not_includes ContentBody.column_names, "readable_text_override"
    assert_not_includes ContentBody.column_names, "lock_version"
    assert_not_includes ContentBody.column_names, "owner_kind"
  end

  test "an upload delegates file facts to the normal Active Storage proxy" do
    upload = build_upload
    upload.save!

    assert_instance_of ActiveStorage::Attached::One, upload.file
    assert_equal "clip.wav", upload.filename.to_s
    assert_equal "audio-bytes".bytesize, upload.byte_size
    assert_equal "audio/wav", upload.content_type
  end

  private

    def create_one_shot
      OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
    end

    def build_one_shot_body
      create_one_shot.content_bodies.build(
        role: "input"
      )
    end

    def build_upload(account: @account, creating_user: users(:system))
      bytes = "audio-bytes"
      account.content_uploads.new(
        creating_user: creating_user,
        file: create_uploaded_blob(bytes: bytes)
      )
    end

    def create_uploaded_blob(bytes:)
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(bytes), filename: "clip.wav", content_type: "audio/wav"
      )
    end
end
