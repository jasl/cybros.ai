require "test_helper"

# Turning submitted upload references into rows the writer may bind. Staging reads are
# creator-scoped in v1, and the scoping is only real if another creator's upload is
# indistinguishable from one that never existed — otherwise the refusal itself answers "does this id
# exist".
class ContentUploads::ResolveReferencesTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @creator = users(:member)
  end

  def resolve(public_ids, creator: @creator)
    ContentUploads::ResolveReferences.call(
      account: @account, creator: creator, public_ids: public_ids
    )
  end

  test "references resolve to rows in submitted order" do
    first = upload
    second = upload

    result = resolve([second.public_id, first.public_id])

    assert_predicate result, :accepted?
    assert_equal [second.id, first.id], result.uploads.map(&:id),
      "submitted order is the binding order the writer will use"
  end

  test "resolved uploads carry their normal Active Storage facts without another query" do
    only = upload

    result = resolve([only.public_id])

    assert_predicate result, :accepted?
    assert_no_queries do
      resolved = result.uploads.sole
      assert_equal "a.txt", resolved.filename.to_s
      assert_operator resolved.byte_size, :positive?
      assert_equal "text/plain", resolved.content_type
    end
  end

  test "another creator's upload is refused exactly like one that never existed" do
    stranger = upload(creating_user: users(:curator))

    foreign = resolve([stranger.public_id])
    unknown = resolve([SecureRandom.uuid_v7])

    assert_not_predicate foreign, :accepted?
    assert_equal unknown.refusal, foreign.refusal,
      "a distinguishable refusal would turn this into an existence oracle"
    assert_nil foreign.uploads
  end

  test "a fileless row is refused at the upload-reference boundary" do
    fileless = @account.content_uploads.create!(creating_user: @creator)

    result = resolve([fileless.public_id])

    assert_not_predicate result, :accepted?
    assert_equal ContentUploads::ResolveReferences::REFUSAL, result.refusal
  end

  # The Create boundary represents an unreadable UUID as nil. This inner
  # resolver trusts that shape and lets it miss by the same path as an unknown
  # canonical UUID.
  test "a normalized unreadable reference is refused by matching nothing" do
    assert_equal resolve([SecureRandom.uuid_v7]).refusal, resolve([nil]).refusal
  end

  test "no references resolve to no uploads" do
    result = resolve([])

    assert_predicate result, :accepted?
    assert_empty result.uploads
  end

  # Duplicate references are the workload contract's question, not this one:
  # resolution answers only which rows the caller may bind.
  test "a repeated reference resolves once per submission" do
    only = upload

    result = resolve([only.public_id, only.public_id])

    assert_predicate result, :accepted?
    assert_equal [only.id, only.id], result.uploads.map(&:id)
  end

  private

    def upload(creating_user: @creator)
      bytes = "bytes-#{SecureRandom.hex(4)}"
      @account.content_uploads.create!(
        creating_user: creating_user,
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "a.txt", content_type: "text/plain"
        )
      )
    end
end
