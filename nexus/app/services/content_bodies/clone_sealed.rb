module ContentBodies
  # Identity-copies a sealed body onto a new owner: pointer rows onto the
  # same fragments, zero content bytes, nothing re-proven.
  class CloneSealed
    def self.call(...) = new(...).call

    def initialize(source:, owner:, role:)
      @source = source
      @owner = owner
      @role = role
    end

    def call
      body = @owner.content_bodies.create!(
        role: @role, readable_text: @source.readable_text, byte_size: @source.byte_size
      )
      copy_entries(body)
      copy_uploads(body)
      body.seal
      body
    end

    private

      def copy_entries(body)
        now = Time.current
        rows = @source.content_body_entries.reorder(:position)
          .pluck(:content_fragment_id, :position)
          .map do |fragment_id, position|
            {
              account_id: body.account_id,
              content_body_id: body.id,
              content_fragment_id: fragment_id,
              position: position,
              created_at: now,
              updated_at: now,
            }
          end
        ContentBodyEntry.insert_all!(rows) if rows.any?
      end

      def copy_uploads(body)
        rows = @source.content_body_uploads.pluck(:content_upload_id).map do |upload_id|
          { content_body_id: body.id, content_upload_id: upload_id }
        end
        ContentBodyUpload.insert_all!(rows) if rows.any?
      end
  end
end
