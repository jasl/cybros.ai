require "test_helper"

# THE ONE REPRESENTATION TABLE: three entries over Active Storage's own `blob.representation` — the
# two named reads' bounds and the assembly's prepared variant — one mechanism; availability is
# Active Storage's answer per blob and per host (a previewer decides for a PDF, and a host without
# poppler has none).
class ContentUploads::RepresentationsTest < ActiveSupport::TestCase
  def blob(bytes, filename, content_type)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(bytes), filename: filename, content_type: content_type)
  end

  test "an image has every kind; a text file has none" do
    picture = blob(PngFixture.bytes(width: 4, height: 4), "p.png", "image/png")
    note = blob("plain words".b, "n.txt", "text/plain")

    assert ContentUploads::Representations.available?(picture)
    refute ContentUploads::Representations.available?(note)
    assert_raises(ActiveStorage::UnrepresentableError) { ContentUploads::Representations.thumbnail(note) }
  end

  test "the named reads and the prepared variant are one mechanism: a bound on the longest edge" do
    picture = blob(PngFixture.bytes(width: 400, height: 300), "wide.png", "image/png")

    thumbnail = ContentUploads::Representations.thumbnail(picture)
    assert_equal "image/png", thumbnail.content_type
    assert_equal [256, 192], PngFixture.dimensions(thumbnail.download), "the thumbnail's longest edge is 256"

    preview = ContentUploads::Representations.preview(picture)
    assert_equal [400, 300], PngFixture.dimensions(preview.download), "under the preview's bound the size is kept"

    prepared = ContentUploads::Representations.prepared(picture, 100)
    assert_equal [100, 75], PngFixture.dimensions(prepared.download), "the lane's own bound, the same table"
    assert_equal "wide.png", prepared.filename.to_s
  end

  # A PDF is representable exactly when a previewer accepts it — the
  # host's `pdftoppm` decides; with no previewer the blob has NO
  # representation, which is the typed refusal's ground, never a crash.
  test "a PDF's availability is the host's previewer's answer" do
    document = blob(PdfFixture::MINIMAL, "page.pdf", "application/pdf")

    ActiveStorage.stub(:previewers, []) do
      refute ContentUploads::Representations.available?(document), "no previewer, no representation"
    end

    skip "no pdftoppm on this host" unless ActiveStorage::Previewer::PopplerPDFPreviewer.pdftoppm_exists?
    assert ContentUploads::Representations.available?(document)
    rendered = ContentUploads::Representations.thumbnail(document)
    assert_equal "image/png", rendered.content_type, "a page rendered by poppler, then bounded"
    width, height = PngFixture.dimensions(rendered.download)
    assert_operator width, :<=, 256
    assert_operator height, :<=, 256
  end

  # THE ONE SHAPE (audit rails-native-19): every entry is a
  # `VariantWithRecord` whose `image.blob` IS the bounded bytes — what the
  # reads hand to `send_blob_stream`. Verified on both origins: an image's
  # variant, and a PDF's preview, where Active Storage's `Preview#image` is
  # the page render at its natural size and the bounded bytes live one
  # level down — the table hands back that level.
  test "every entry's image.blob is the bounded bytes: an image's variant and a PDF's preview alike" do
    picture = blob(PngFixture.bytes(width: 400, height: 300), "wide.png", "image/png")
    thumbnail = ContentUploads::Representations.thumbnail(picture)
    assert_kind_of ActiveStorage::VariantWithRecord, thumbnail
    assert_equal thumbnail.download.b, thumbnail.image.blob.download.b
    assert_equal [256, 192], PngFixture.dimensions(thumbnail.image.blob.download)
    assert_equal "image/png", thumbnail.image.blob.content_type

    skip "no pdftoppm on this host" unless ActiveStorage::Previewer::PopplerPDFPreviewer.pdftoppm_exists?
    document = blob(PdfFixture::MINIMAL, "page.pdf", "application/pdf")
    preview = ContentUploads::Representations.thumbnail(document)
    assert_kind_of ActiveStorage::VariantWithRecord, preview, "a Preview's bounded variant, not the Preview"
    assert_equal preview.download.b, preview.image.blob.download.b
    width, height = PngFixture.dimensions(preview.image.blob.download)
    assert_operator width, :<=, 256
    assert_operator height, :<=, 256
    page = document.reload.preview_image.blob
    refute_equal page.checksum, preview.image.blob.checksum, "the page render at its natural size is NOT the bounded bytes"
    assert_equal preview.image.blob.checksum, ContentUploads::Representations.thumbnail(document).image.blob.checksum,
      "the second read is a lookup of the same tracked variant"
  end
end
