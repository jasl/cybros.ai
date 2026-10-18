require "test_helper"

# THE TWO NAMED REPRESENTATION READS: `GET /agent_api/v1/uploads/{id}/thumbnail` and `/preview` —
# presets named in code over the one table (`ContentUploads::Representations`), under the same rule
# as `bytes` (absent, foreign, fileless and unreadable are 404 alike), whole and inline; a blob with
# no representation of that kind answers the typed `404 representation_unavailable`, never a crash.
# EVERY attachment read is a conditional GET: a strong ETag of the blob's checksum and the kind,
# `Cache-Control: private, max-age=<a year>`, a matching `If-None-Match` → 304 with no body; another
# kind's tag misses.
class AgentAPI::V1::UploadRepresentationsTest < ActionDispatch::IntegrationTest
  include AgentMembershipTestHelper

  MAX_AGE = 1.year.to_i
  # A picture wider than the thumbnail's bound and inside the preview's.
  WIDE = PngFixture.bytes(width: 400, height: 300)

  setup do
    @account = accounts(:cybros)
    @member = create_access_token_fixture(user: users(:member), name: "M")
    @owner = create_access_token_fixture(user: users(:owner), name: "O")
  end

  def bearer(secret) = { "Authorization" => "Bearer #{secret}" }

  def read(kind, public_id, secret, etag: nil)
    headers = bearer(secret)
    headers["If-None-Match"] = etag if etag
    get send(:"agent_api_v1_upload_#{kind}_path", upload_public_id: public_id), headers: headers
  end

  def staged(bytes, filename, content_type, **creator)
    creator = { creating_user: users(:member) } if creator.empty?
    @account.content_uploads.create!(
      **creator,
      file: ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename,
        content_type: content_type)
    )
  end

  def assert_cacheable_private
    assert_match(/\A"[0-9a-f]+"\z/, response.headers["ETag"], "a strong tag: never W/")
    directives = response.headers["Cache-Control"].split(",").map(&:strip)
    assert_includes directives, "private", "ACL'd: never public"
    assert_includes directives, "max-age=#{MAX_AGE}"
    assert_equal Nexus::Contract.pack.fetch("uploads.json").fetch("attachment_cache_control"),
      response.headers["Cache-Control"], "the pack's row is the header, byte for byte"
  end

  test "the thumbnail is the picture bounded at 256 and the preview at 1600, inline, the same table" do
    picture = staged(WIDE, "wide.png", "image/png")

    read(:thumbnail, picture.public_id, @member.secret)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_match(/inline/, response.headers["Content-Disposition"])
    assert_equal [256, 192], PngFixture.dimensions(response.body), "the longest edge is 256: a smaller PNG"

    read(:preview, picture.public_id, @member.secret)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_equal [400, 300], PngFixture.dimensions(response.body), "under the preview's bound the size is kept"
    assert_equal ContentUploads::Representations.preview(picture.file.blob).download.b, response.body.b,
      "the route serves the table's own entry"
  end

  test "a blob with no representation of that kind is the typed refusal, never a crash" do
    note = staged("plain words".b, "note.txt", "text/plain")

    read(:thumbnail, note.public_id, @member.secret)
    assert_response :not_found
    assert_equal "representation_unavailable", response.parsed_body.dig("error", "code")
    assert_includes response.parsed_body.dig("error", "message"), "text/plain"

    read(:preview, note.public_id, @member.secret)
    assert_response :not_found
    assert_equal "representation_unavailable", response.parsed_body.dig("error", "code")
  end

  # The host decides for a PDF: with no previewer (a host without
  # poppler) the blob has no representation — the same typed word.
  test "a PDF on a host without poppler answers the typed refusal" do
    document = staged(PdfFixture::MINIMAL, "page.pdf", "application/pdf")

    ActiveStorage.stub(:previewers, []) do
      read(:preview, document.public_id, @member.secret)
    end
    assert_response :not_found
    assert_equal "representation_unavailable", response.parsed_body.dig("error", "code")
  end

  # A render that fails (a corrupt image, a previewer's crash, a vanished
  # file) is the same typed refusal — and a refusal is never cacheable: the
  # validator and the year `fresh_when` set for the bytes that were expected
  # must not ride the 404, or a transient failure is cached as the picture.
  test "a render failure is the typed refusal and carries no validator and no freshness" do
    picture = staged(WIDE, "wide.png", "image/png")

    ContentUploads::Representations.stub(:thumbnail, ->(_blob) { raise "libvips: corrupt image" }) do
      read(:thumbnail, picture.public_id, @member.secret)
    end
    assert_response :not_found
    assert_equal "representation_unavailable", response.parsed_body.dig("error", "code")
    assert_nil response.headers["ETag"], "a refusal carries no validator"
    refute_match(/max-age=#{MAX_AGE}/, response.headers["Cache-Control"].to_s, "a refusal is never a year fresh")
  end

  test "absent, foreign and fileless answer the plain 404; an executor credential 401" do
    mine = staged(WIDE, "wide.png", "image/png")

    read(:thumbnail, mine.public_id, @owner.secret)
    assert_response :not_found
    assert_equal "not_found", response.parsed_body.dig("error", "code"), "another member's row is absence, never its type"

    read(:thumbnail, SecureRandom.uuid_v7, @member.secret)
    assert_response :not_found

    fileless = @account.content_uploads.create!(creating_user: users(:member))
    read(:preview, fileless.public_id, @member.secret)
    assert_response :not_found

    read(:thumbnail, mine.public_id, suite_runner_connection.executor_access_secret)
    assert_response :unauthorized
  end

  test "every attachment read is a conditional GET: one strong tag per kind, a year private, 304 on a match" do
    picture = staged(WIDE, "wide.png", "image/png")
    tags = {}

    %i[bytes thumbnail preview].each do |kind|
      read(kind, picture.public_id, @member.secret)
      assert_response :success, kind.to_s
      assert_cacheable_private
      tags[kind] = response.headers["ETag"]

      read(kind, picture.public_id, @member.secret)
      assert_equal tags[kind], response.headers["ETag"], "#{kind}: the tag is the immutable upload's, stable across reads"

      read(kind, picture.public_id, @member.secret, etag: tags[kind])
      assert_response :not_modified, "#{kind}: a matching If-None-Match"
      assert_empty response.body.to_s, "#{kind}: a 304 carries no bytes"
      assert_equal tags[kind], response.headers["ETag"]
    end
    assert_equal 3, tags.values.uniq.length, "one checksum, three kinds, three tags: #{tags.inspect}"

    read(:bytes, picture.public_id, @member.secret, etag: tags[:thumbnail])
    assert_response :success, "another kind's tag misses"
    assert_equal WIDE.b, response.body.b
    read(:thumbnail, picture.public_id, @member.secret, etag: tags[:bytes])
    assert_response :success
    assert_equal [256, 192], PngFixture.dimensions(response.body)
  end

  test "a Range read of the bytes still answers the tag, and a match beats the slice" do
    picture = staged(WIDE, "wide.png", "image/png")
    read(:bytes, picture.public_id, @member.secret)
    tag = response.headers["ETag"]

    get agent_api_v1_upload_bytes_path(upload_public_id: picture.public_id),
      headers: bearer(@member.secret).merge("Range" => "bytes=0-7")
    assert_response :partial_content
    assert_equal tag, response.headers["ETag"], "the slice is the same immutable bytes"

    get agent_api_v1_upload_bytes_path(upload_public_id: picture.public_id),
      headers: bearer(@member.secret).merge("Range" => "bytes=0-7", "If-None-Match" => tag)
    assert_response :not_modified
  end
end
