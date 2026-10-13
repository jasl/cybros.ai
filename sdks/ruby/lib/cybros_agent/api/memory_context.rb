module CybrosAgent
  module Api
    # Durable memory behind member-plane doors that share one grammar.
    #
    # A conversation's door (`chat.memory`) serves its named bindings or,
    # by default, its own scope, its workspace's, the `agent/` scope of its
    # answering agent and the current input's `speaker/` scope. A member
    # request has no input speaker: its speaker binding needs an explicit
    # `speaker_public_id`. The workspace's door (`workspace.memory`) serves the
    # `workspace/` scope alone: the room's rows, written without picking
    # a conversation. The profile's door (`client.profile.memory`) serves
    # the Human's own `user/` scope — notes which follow the person across
    # workspaces — or, for an Agent caller, its own `agent/` scope: notes
    # anchored to that Agent's User row. The declarer manages a named
    # definition's own `agent/` scope at `client.profile.agents.memory(name:)`. The pack's `door_scopes`
    # names each door's scopes.
    #
    # An assembled reply reads bound documents in its memory block.
    # These member doors manage those documents; an execution accesses the
    # same memory through its declared memory tools.
    #
    # THE PATH CARRIES THE SCOPE as its first segment — `workspace/notes.md`,
    # `conversation/plan.md`, `speaker/notes.md`, `agent/notes.md` — on every door, which is why
    # every verb takes it in the BODY, reads included. A bare name is
    # refused rather than defaulted: the scopes differ in who can read
    # them, and a default would decide that by accident. A scope a door
    # does not serve (`workspace/` at the profile's, `user/` at the
    # workspace's) is the kernel's `memory_scope_unavailable`, typed as
    # `InvalidRequest`.
    class MemoryContext
      include ConversationProjections

      attr_reader :path

      # `path` is the door: the memory collection this context reads and
      # writes, already spelled by the owning context.
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

      # Replace only the document version the caller read. Two explicit nil
      # conditions create only when the path is absent. A stale condition
      # raises Conflict; callers must reconcile a lost response or a newer
      # edit themselves, never retry old content against a freshly read version.
      #
      # Through a conversation's door it bumps that conversation's
      # `context_revision`, because it changes what the next reply is
      # assembled from; through the profile's door there is no
      # conversation to bump — future execution reads its bound roots live.
      #
      # Skills use `skills/<name>` within an available user, workspace,
      # agent or speaker binding, subject to that door's principal and access.
      # `description:` is required there (`skill_description_required`) and
      # refused on ordinary documents (`memory_description_invalid`). The name
      # follows the skill grammar (`skill_name_invalid`); conversation-scoped
      # skills are refused (`skill_scope_unavailable`). The description is sent
      # only when given.
      def write(document_path, content, expected_public_id:, expected_lock_version:, description: nil)
        fields = { "path" => document_path, "content" => content,
                   "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }
        fields["description"] = description unless description.nil?
        shape(MemoryDocument, @dispatch.call(path, method: :post, success: 201, body: { "memory" => memory_fields(fields) }), "memory")
      end

      # Replace one exact text occurrence at the version the caller read.
      # Conflicts surface unchanged; this never reads or retries a newer row.
      def edit(path:, old_text:, new_text:, expected_public_id:, expected_lock_version:)
        fields = { "path" => path, "old_text" => old_text, "new_text" => new_text,
                   "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }
        shape(MemoryDocument, @dispatch.call("#{@path}/edit", method: :post, body: { "memory" => memory_fields(fields) }), "memory")
      end

      # Gone for good — no history, no recycle bin. A conversation forked
      # from this one keeps its own copy; this does not reach it. The required
      # identity/version pair also refuses deletion of a recreated document.
      def delete(document_path, expected_public_id:, expected_lock_version:)
        @dispatch.call("#{path}/delete", method: :post, success: 204,
          body: { "memory" => memory_fields("path" => document_path,
                               "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version) })
        nil
      end

      private

        def memory_fields(fields)
          @speaker_public_id ? fields.merge("speaker_public_id" => @speaker_public_id) : fields
        end
    end
  end
end
