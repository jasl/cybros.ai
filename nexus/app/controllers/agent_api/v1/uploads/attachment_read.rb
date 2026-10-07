# WHAT THE THREE ATTACHMENT READS SHARE (`bytes`, `thumbnail`, `preview`):
# the upload found by its OWN rule (`ContentUpload#readable_by?` — its
# creator, or a reader of a row that names it; absent, foreign, fileless
# and unreadable answer 404 alike, no oracle), and the CONDITIONAL GET
# every read answers. An upload is immutable, so each read carries a
# strong `ETag` derived from the blob's checksum and the read's kind
# (Rails' own `fresh_when`), `Cache-Control: private, max-age=<a year>` —
# private because the read is ACL'd, never `public` — and an
# `If-None-Match` that matches is a 304 BEFORE a byte is rendered or
# streamed. The representation reads sit on the one table
# (`ContentUploads::Representations`): a blob with no representation of
# that kind answers the typed refusal `404 representation_unavailable`,
# never a crash.
module AgentAPI::V1::Uploads::AttachmentRead
  extend ActiveSupport::Concern
  include ActiveStorage::Streaming

  # The bytes never change: a year is HTTP's own "as long as you like".
  MAX_AGE = 1.year

  included do
    serves_plane :member
  end

  private

    def readable_upload
      upload = acting_user.account.content_uploads.with_attached_file
        .find_by!(public_id: params.fetch(:upload_public_id))
      raise ActiveRecord::RecordNotFound unless upload.file.attached? && upload.readable_by?(acting_user)

      upload
    end

    # True when the caller's `If-None-Match` matched and the 304 is already
    # on the response; false when there are bytes to send.
    def answered_fresh?(blob, kind)
      fresh_when(strong_etag: [blob.checksum, kind], cache_control: { max_age: MAX_AGE.to_i })
      performed?
    end

    # ONE representation read: the named entry of the table, whole, no
    # `Range` (a representation is small), inline — a picture for a UI —
    # streamed by Active Storage's own `send_blob_stream` from the
    # representation's IMAGE BLOB (`image.blob` on a `Preview` and on a
    # `VariantWithRecord` alike), the same call the `bytes` read makes.
    def send_representation(kind)
      upload = readable_upload
      blob = upload.file.blob
      return render_representation_unavailable(upload, kind) unless ContentUploads::Representations.available?(blob)
      return if answered_fresh?(blob, kind)

      representation = rendered(upload, kind)
      return if representation.nil?

      send_blob_stream(representation.image.blob, disposition: "inline")
    end

    # The render is the one call three libraries can fail (a corrupt
    # image, a previewer's process, a vanished file): each means "no
    # representation of that kind", answered typed — the assembly's
    # `UploadMedia.processed` reads the same failures the same way.
    def rendered(upload, kind)
      ContentUploads::Representations.public_send(kind, upload.file.blob)
    rescue StandardError => error
      Rails.error.report(error, handled: true,
        context: { event: "upload_representation_failed", upload: upload.public_id, kind: kind })
      render_representation_unavailable(upload, kind)
      nil
    end

    # A refusal is never cacheable: after `fresh_when` (a render that
    # failed) the validator and the year set for the expected bytes would
    # otherwise ride the 404, and a transient failure be cached as the
    # picture.
    def render_representation_unavailable(upload, kind)
      response.headers.delete("ETag")
      expires_now
      render_error(:representation_unavailable,
        "upload #{upload.public_id} (#{upload.content_type}) has no #{kind}", status: :not_found)
    end

    def acting_user
      current_credential.user
    end
end
