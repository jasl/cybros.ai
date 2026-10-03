module ContentBodies
  # The single write path for body content: replaced whole, measured
  # once at the boundary that forms it, decomposed per message so a loop
  # stores only the message that changed.
  class Replace
    Result = Data.define(:body, :refusal) do
      def self.accepted(body) = new(body: body, refusal: nil)
      def self.refused(refusal) = new(body: nil, refusal: refusal)

      def accepted? = refusal.nil?
    end

    def self.call(...) = new(...).call

    # A kernel-composed request binds only what it sends: the invocation's
    # `request` body, and the loop seed the reply lane seals onto round one
    # (`composed: true`) — the same assembled list under the node's `input`
    # role. Their upload rows are the PLACED set of pictures history's own
    # doors already bounded, counted distinct (`insert_uploads`); the
    # upload-bytes bound is a door's, never theirs, or 65 turns of phone
    # photos would refuse turn 66's seal and arm compaction on bytes the
    # word wall cannot measure.
    COMPOSED_ROLE = "request".freeze

    # `readable_text` is the WRITER's word when it is writing a person's
    # message: the words of the text parts, `""` for a picture with no words
    # — never a projection over the parts here, which would fire on every
    # sealed request and render an assembled list as `User:`. Every other
    # writer leaves it nil and keeps today's top-level projection.
    def initialize(owner:, role:, entries:, uploads: [], seal: false, readable_text: nil,
                   composed: false)
      @owner = owner
      @role = role
      @entries = entries
      @uploads = uploads
      @seal = seal
      @given_readable_text = readable_text
      @composed = composed || role == COMPOSED_ROLE
    end

    def call
      refusal = bound_refusal
      return Result.refused(refusal) if refusal

      return create_and_seal if @seal

      result = nil
      ContentBody.transaction(requires_new: true) do
        body = locked_body
        result = replace_body(body)
        raise ActiveRecord::Rollback unless result.accepted?
      end
      result
    end

    private

      # Production content is create-and-seal. Its callers already own the
      # surrounding transaction and the owner-row serialization point, so this
      # path forms the new body directly without another savepoint or lock.
      def create_and_seal
        body = create_body
        fragments = resolved_fragments(body.account)
        insert_entries(body, fragments)
        insert_uploads(body)
        finish(body, seal: true)
        Result.accepted(body)
      end

      # The role singleton serializes on the owner rather than on a partial
      # unique index: two concurrent first-writes for one (owner, role) would
      # otherwise both find nothing and both insert.
      def locked_body
        @owner.with_lock do
          body = @owner.content_bodies.find_by(role: @role)
          next body if body

          create_body
        end
      end

      def create_body
        @owner.content_bodies.create!(
          account: @owner.account, role: @role
        )
      end

      def replace_body(body)
        return Result.refused(:body_sealed) if body.sealed?

        write_children(body)
        finish(body)
        Result.accepted(body)
      end

      def write_children(body)
        fragments = resolved_fragments(body.account)
        replace_entries(body, fragments)
        replace_uploads(body)
      end

      def replace_entries(body, fragments)
        ContentBodyEntry.where(content_body: body).delete_all
        insert_entries(body, fragments)
      end

      def insert_entries(body, fragments)
        rows = @entries.each_with_index.map do |payload, position|
          {
            account_id: body.account_id,
            content_body_id: body.id,
            content_fragment_id: fragments.fetch(address_for(payload).digest).id,
            position: position,
          }
        end
        ContentBodyEntry.insert_all!(rows) if rows.any?
        body.association(:content_body_entries).reset
      end

      def replace_uploads(body)
        ContentBodyUpload.where(content_body: body).delete_all
        insert_uploads(body)
      end

      def insert_uploads(body)
        rows = @uploads.uniq(&:id).map do |upload|
          { content_body_id: body.id, content_upload_id: upload.id }
        end
        ContentBodyUpload.insert_all!(rows) if rows.any?
        body.association(:content_body_uploads).reset
        body.association(:content_uploads).reset
      end

      # No owner row to serialize on: pin existing rows first (closing the
      # orphan-reaper window), insert only missing digests, then adopt those
      # rows through a locked fetch that also covers concurrent winners.
      def resolved_fragments(account)
        addressed_payloads = addressed_payloads_by_digest
        return {} if addressed_payloads.empty?

        # The caller already owns the payloads. Adoption needs only their
        # identities, including when the same request prefix is sealed again.
        relation = account.content_fragments.select(:id, :digest)
          .order(:digest)
          .lock("FOR KEY SHARE")
        fragments = relation.where(digest: addressed_payloads.keys).index_by(&:digest)

        rows = addressed_payloads.filter_map do |digest, (payload, address)|
          unless fragments.key?(digest)
            {
              account_id: account.id,
              payload: payload,
              digest: digest,
            }
          end
        end
        if rows.any?
          ContentFragment.insert_all(
            rows,
            unique_by: :index_content_fragments_on_account_id_and_digest,
            returning: false
          )
          fragments.merge!(relation.where(digest: rows.pluck(:digest)).index_by(&:digest))
        end

        fragments
      end

      def addressed_payloads_by_digest
        @addressed_payloads_by_digest ||= addresses
          .each_with_object({}) do |(payload, address), result|
            result[address.digest] ||= [payload, address]
          end
          .sort_by(&:first)
          .to_h
      end

      def addresses
        @addresses ||= @entries.uniq.to_h do |payload|
          [
            payload,
            Nexus::ContentAddress.for(account_id: @owner.account_id, payload: payload),
          ]
        end
      end

      def address_for(payload)
        addresses.fetch(payload)
      end

      def finish(body, seal: false)
        body.update!(readable_text: readable_text, byte_size: byte_size,
          **(seal ? { sealed_at: Time.current } : {}))
      end

      # THE STORED SIZE: the bytes `effective_text` will answer — the
      # projection's when the entries project one, otherwise the canonical
      # entries joined by a newline — stamped by the write that forms the
      # entries, so no reader ever loads a body to measure it.
      def byte_size
        return @given_readable_text.bytesize unless @given_readable_text.nil?

        text = readable_text.presence
        return text.bytesize if text
        return 0 if @entries.empty?

        aggregate_bytes + @entries.length - 1
      end

      # The body total counts each canonical entry once — THE ONE MEASURE
      # (`ContentBodies::Measure`) over the addresses already formed for the
      # digests. `readable_text` is a projection of those same entries, not
      # another payload to charge; any referenced binary bytes are bounded at
      # their own input boundary.
      def measured
        @measured ||= Measure.of_sizes(@entries.map { |payload| address_for(payload).byte_size })
      end

      def aggregate_bytes = measured.bytes

      # InputEntries closed every entry to a Hash at the caller's input
      # boundary. Read that shape directly; a message entry simply has no
      # top-level text and leaves the fallback chain free to serialize it.
      def readable_text
        return @given_readable_text unless @given_readable_text.nil?
        return @readable_text if defined?(@readable_text)

        texts = @entries.filter_map { |payload| payload["text"] }
        @readable_text = texts.empty? ? nil : texts.join("\n")
      end

      # Every check the newly formed aggregate must pass, once, before any row
      # moves. Counts and bytes are different dimensions with different typed
      # rejections.
      def bound_refusal
        unless Nexus::SizeBounds.count_within?(:body_entry_count_bound, @entries.length)
          return Nexus::SizeBounds::COUNT_REJECTION
        end
        unless Nexus::SizeBounds.count_within?(:body_upload_count_bound, @uploads.length)
          return Nexus::SizeBounds::COUNT_REJECTION
        end
        # Every entry and the aggregate against the body's bound — the
        # measure the preview's `storage` line reports, so the two agree.
        return measured.refusal unless measured.within_bound?
        if !@composed && !Nexus::SizeBounds.bytes_within?(:body_upload_bytes_bound, upload_bytes)
          return Nexus::SizeBounds::REJECTION
        end

        nil
      rescue Nexus::CanonicalJson::UnsupportedNumber
        :unsupported_number
      rescue Nexus::CanonicalJson::UnsupportedText
        # Proving it can be measured has to mean proving it can be stored,
        # or the INSERT below aborts the whole create.
        :unsupported_text
      rescue Nexus::CanonicalJson::UnsupportedValue
        # The parent class, which the encoder also raises bare (a non-JSON
        # value, a non-String key); catching only the children leaves a 500.
        :unsupported_value
      end

      # Counted once per submitted occurrence, so repeated media placements
      # retain their request bound even though liveness uses one join row.
      def upload_bytes
        @uploads.sum(&:byte_size)
      end
  end
end
