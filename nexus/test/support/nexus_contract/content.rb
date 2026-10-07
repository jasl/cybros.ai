module Nexus
  module Contract
    # Inputs chosen so that every decision the canonical encoder makes shows up in the pinned bytes:
    # key ordering, nesting through both containers, non-ASCII, HTML-sensitive and escape-forcing
    # text, integer and decimal number forms (including signed zero), the empty containers, and JSON
    # null as a value. A second implementation that reproduces these digests has reproduced the
    # encoding.
    CONTENT_ADDRESS_VECTORS = [
      { "name" => "empty_object", "account_id" => 1, "payload" => {} },
      { "name" => "empty_array", "account_id" => 1, "payload" => [] },
      { "name" => "scalar_string", "account_id" => 1, "payload" => "text" },
      {
        "name" => "key_order_is_normalized", "account_id" => 1,
        "payload" => { "b" => 1, "a" => 2, "C" => 3, "0" => 4 },
      },
      {
        "name" => "account_salt_changes_the_digest", "account_id" => 2,
        "payload" => { "b" => 1, "a" => 2, "C" => 3, "0" => 4 },
      },
      {
        "name" => "nested_containers", "account_id" => 1,
        "payload" => { "z" => [1, { "y" => [], "x" => {} }], "a" => { "n" => nil } },
      },
      {
        "name" => "number_forms", "account_id" => 1,
        "payload" => { "i" => 0, "neg" => -17, "big" => 9007199254740991 },
      },
      { "name" => "ordinary_decimal_float", "account_id" => 1, "payload" => { "n" => 1.5 } },
      { "name" => "positive_zero_float", "account_id" => 1, "payload" => { "n" => 0.0 } },
      { "name" => "negative_zero_float", "account_id" => 1, "payload" => { "n" => -0.0 } },
      {
        "name" => "text_escapes_and_non_ascii", "account_id" => 1,
        "payload" => { "quote" => "a\"b", "backslash" => "a\\b", "tab" => "a\tb",
                       "newline" => "a\nb", "unicode" => "日本語 · émoji 🙂" },
      },
      {
        "name" => "html_sensitive_text", "account_id" => 1,
        "payload" => { "html" => "<tag>&value>" },
      },
      { "name" => "booleans", "account_id" => 1, "payload" => { "t" => true, "f" => false } },
    ].freeze

    class << self
      private

        # THE UPLOAD DOORS: one ingest — `multipart/form-data`, one part `upload[file]`, the bytes
        # decide the type — behind the member plane's `POST /agent_api/v1/uploads`, the session door
        # and the executor plane's `POST /agent_api/v1/executor/uploads` (a CAPTURE, staged as that
        # executor's own), each answering the SAME descriptor; the creator is exactly one of a
        # member or an executor. ONE bytes read on the member plane, by the upload's own rule (the
        # creator, or a reader of a row that names it): whole with `Accept-Ranges: bytes`, a `Range`
        # answers 206 and the slice; absent, foreign and unreadable are 404 alike. TWO NAMED
        # REPRESENTATION READS beside it: the thumbnail and the preview, presets named in code, the
        # same rule; a blob with no representation of that kind is `representation_unavailable`.
        # Member attachment reads are conditional GETs: a strong ETag, a year private,
        # `If-None-Match` → 304. Claim-scoped executor reads are always no-store.
        def uploads
          staged = Data.define(:public_id, :filename, :content_type, :byte_size, :created_at).new(
            public_id: UPLOAD_PUBLIC_ID, filename: "shot.png", content_type: "image/png",
            byte_size: 184_211, created_at: Time.utc(2026, 9, 13, 0, 0, 0)
          )
          descriptor = stringify_keys(AgentAPI::UploadPresenter.full(staged))
          {
            "ingest_paths" => {
              "member" => "/agent_api/v1/uploads",
              "session" => "/uploads",
              "executor" => "/agent_api/v1/executor/uploads",
            },
            "ingest_part" => "upload[file]",
            "ingest_status" => 201,
            "descriptor_projection" => descriptor.keys,
            "creators" => %w[creating_user creating_executor],
            "bytes_path" => "/agent_api/v1/uploads/{public_id}/bytes",
            "bytes_statuses" => { "whole" => 200, "range" => 206, "fresh" => 304, "absent" => 404 },
            "executor_attachment" => {
              "descriptor_path" => "/agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{public_id}",
              "bytes_path" => "/agent_api/v1/executor/inbox/{run_public_id}/{task_key}/attachments/{public_id}/bytes",
              "claim_header" => "Claim-Token",
              "cache_control" => "no-store",
              "statuses" => { "whole" => 200, "range" => 206, "absent" => 404, "not_claimant" => 409, "claim_inactive" => 409 },
            },
            "representation_paths" => {
              "thumbnail" => "/agent_api/v1/uploads/{public_id}/thumbnail",
              "preview" => "/agent_api/v1/uploads/{public_id}/preview",
            },
            "representation_bounds" => ContentUploads::Representations::NAMED,
            "representation_statuses" => { "whole" => 200, "fresh" => 304, "unavailable" => 404 },
            # Rails' own spelling (`max-age` first): a consumer may compare the string.
            "attachment_cache_control" => "max-age=#{AgentAPI::V1::Uploads::AttachmentRead::MAX_AGE.to_i}, private",
            "error_statuses" => UPLOAD_ERROR_STATUSES,
            "valid_fixture" => { "upload" => descriptor },
            "unknown_field_behavior" => "ignore",
          }
        end

        # Name, unit, and value together: a consumer that reads only the number cannot tell 256
        # entries from 256 bytes.
        def size_bounds
          {
            "bounds" => Nexus::SizeBounds::BOUNDS.to_h do |name, entry|
              [name.to_s, { "unit" => entry.fetch(:unit).to_s, "value" => entry.fetch(:value) }]
            end,
            "rejection_code" => Nexus::SizeBounds::REJECTION.to_s,
            "count_rejection_code" => Nexus::SizeBounds::COUNT_REJECTION.to_s,
            # The progress door's cadence floor: milliseconds per key per kernel process, not a size
            # — named here because a runner MIRRORS it and its suite pins the mirror equal to this.
            "progress_min_interval_ms" => Executors::Progress::MIN_INTERVAL_MS,
          }
        end

        # The canonical encoding's BYTE behavior, pinned across processes. Stored digests bake this
        # encoder in, so changing it is a breaking migration rather than a refactor — and the
        # mechanism that makes that claim true is here: these vectors are regenerated from the
        # shipped encoder, so any change to it produces a visible pack diff that the drift check
        # refuses to let pass silently.
        #
        # An in-process byte-pin test cannot do this job alone, because it is
        # edited in the same commit as the encoder it guards.
        def content_addressing
          {
            "encoding" => "canonical_json",
            "digest_algorithm" => "sha256",
            # Account-salted: the same bytes converge to one row inside one
            # trust domain and never across two.
            "digest_input" => "{account_id}\n{canonical_payload}",
            "digest_separator_hex" => "0a",
            "vectors" => CONTENT_ADDRESS_VECTORS.map do |vector|
              address = Nexus::ContentAddress.for(
                account_id: vector.fetch("account_id"), payload: vector.fetch("payload")
              )

              vector.merge(
                "canonical_payload" => address.canonical_payload,
                "byte_size" => address.byte_size,
                "digest" => address.digest
              )
            end,
            # Values the encoder refuses rather than encodes. `invalid_utf8`
            # has no JSON representation and so carries no payload here; it is
            # named because a second implementation must reject it too.
            "rejections" => {
              "unsupported_number" =>
                ["NaN", "Infinity", "-Infinity", "finite_exponent_form_float"],
              "unsupported_text" => ["u0000_in_value", "u0000_in_key", "invalid_utf8"],
            },
          }
        end
    end
  end
end
