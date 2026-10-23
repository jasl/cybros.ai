module CybrosAgent
  module Api
    # Document commands addressed by collection UUID and relative path.
    module MemoryDocumentOperations
      include ConversationProjections

      attr_reader :path

      # Constructing a handle performs no request.
      def initialize(dispatch:, path:, speaker_public_id: nil)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
        @speaker_public_id = required_string_snapshot(speaker_public_id, "speaker_public_id") unless speaker_public_id.nil?
      end

      # Everything this door can see, including the row/version pair for
      # conditional writes. Only `read` loads text.
      def list
        params = { "memory[speaker_public_id]" => @speaker_public_id } if @speaker_public_id
        shapes(MemoryDocument, @dispatch.call(path, params: params), "memory")
      end

      def read(document_path)
        shape(MemoryDocument, @dispatch.call("#{path}/show", method: :post,
              body: { "memory" => memory_fields("path" => document_path) }), "memory")
      end

      # Search this door's readable documents; returned paths keep their
      # binding names so a match can be passed directly to read or edit.
      def grep(pattern:, path: nil, ignore_case: false, limit: nil)
        fields = { "pattern" => pattern, "path" => path, "ignore_case" => ignore_case, "limit" => limit }.compact
        answer = @dispatch.call("#{@path}/grep", method: :post, body: { "memory" => memory_fields(fields) })
        { "matches" => json_array(answer, "matches"), "truncated" => boolean(answer, "truncated") }
      end

      protected def write_document(document_path, content, expected_public_id:, expected_lock_version:, description: nil, **identity)
        fields = { "path" => document_path, "content" => content,
                   "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }.merge(identity.transform_keys(&:to_s))
        fields["description"] = description unless description.nil?
        shape(MemoryDocument, @dispatch.call(path, method: :post, success: 201, body: { "memory" => memory_fields(fields) }), "memory")
      end

      protected def edit_document(path:, old_text:, new_text:, expected_public_id:, expected_lock_version:, **identity)
        fields = { "path" => path, "old_text" => old_text, "new_text" => new_text,
                   "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }.merge(identity.transform_keys(&:to_s))
        shape(MemoryDocument, @dispatch.call("#{@path}/edit", method: :post, body: { "memory" => memory_fields(fields) }), "memory")
      end

      protected def delete_document(document_path, expected_public_id:, expected_lock_version:, **identity)
        @dispatch.call("#{path}/delete", method: :post, success: 204,
          body: { "memory" => memory_fields("path" => document_path,
                               "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version, **identity.transform_keys(&:to_s)) })
        nil
      end

      private

        def memory_fields(fields)
          @speaker_public_id ? fields.merge("speaker_public_id" => @speaker_public_id) : fields
        end
    end
    class MemoryDocumentsContext
      include MemoryDocumentOperations

      # Nil document conditions mean create only. Conflicts surface unchanged;
      # callers must reconcile them before submitting another write.
      def write(document_path, content, expected_public_id:, expected_lock_version:, description: nil)
        write_document(document_path, content, expected_public_id:, expected_lock_version:, description:)
      end

      # Replace one exact text occurrence at the version the caller read.
      # Conflicts surface unchanged; this never reads or retries a newer row.
      def edit(path:, old_text:, new_text:, expected_public_id:, expected_lock_version:)
        edit_document(path:, old_text:, new_text:, expected_public_id:, expected_lock_version:)
      end

      # Gone for good — no history, no recycle bin. A conversation forked
      # from this one keeps its own copy; this does not reach it. The required
      # identity/version pair also refuses deletion of a recreated document.
      def delete(document_path, expected_public_id:, expected_lock_version:)
        delete_document(document_path, expected_public_id:, expected_lock_version:)
      end
    end

    # A conversation binding can move independently of its document version.
    # Pin the collection even for an absent path; never resolve it during retry.
    class MemoryContext
      include MemoryDocumentOperations
      def bindings
        params = { "memory[speaker_public_id]" => @speaker_public_id } if @speaker_public_id
        json_object(@dispatch.call(path, params: params), "memory_context")
      end

      def write(document_path, content, expected_collection_public_id:, expected_public_id:, expected_lock_version:, description: nil)
        write_document(document_path, content, expected_collection_public_id:, expected_public_id:, expected_lock_version:, description:)
      end

      def edit(path:, old_text:, new_text:, expected_collection_public_id:, expected_public_id:, expected_lock_version:)
        edit_document(path:, old_text:, new_text:, expected_collection_public_id:, expected_public_id:, expected_lock_version:)
      end

      def delete(document_path, expected_collection_public_id:, expected_public_id:, expected_lock_version:)
        delete_document(document_path, expected_collection_public_id:, expected_public_id:, expected_lock_version:)
      end
    end
  end
end
