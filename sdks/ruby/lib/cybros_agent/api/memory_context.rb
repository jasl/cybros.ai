module CybrosAgent
  module Api
    # DURABLE MEMORY, behind three member-plane doors that share one grammar.
    #
    # A conversation's door (`chat.memory`) serves its named bindings or,
    # by default, its own scope, its workspace's, and the `user/` scope of
    # the caller's controlling Human. The workspace's door (`workspace.memory`) serves the
    # `workspace/` scope alone: the room's rows, written without picking
    # a conversation. The profile's door (`client.profile.memory`) serves
    # the `user/` scope alone: the person's own notes, which follow them
    # across workspaces and which every agent they steward can read. The
    # pack's `door_scopes` names each door's scopes.
    #
    # A `direct_reply` is one model call with no tools, so nothing running
    # inside a conversation can call a memory tool the way an agent run
    # can. What a conversation's model sees is an assembly BLOCK the
    # kernel injects ahead of history — so writing here is how anything
    # gets into that block, and reading here is how a client sees what the
    # model will be shown.
    #
    # THE PATH CARRIES THE SCOPE as its first segment — `workspace/notes.md`,
    # `conversation/plan.md`, `user/notes.md` — on both doors, which is why
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
      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
      end

      # Everything this door can see, including the row/version pair for
      # conditional writes. Only `read` loads text.
      def list = shapes(MemoryDocument, @dispatch.call(path), "memory")

      def read(document_path)
        shape(MemoryDocument, @dispatch.call("#{path}/show", method: :post,
              body: { "memory" => { "path" => document_path } }), "memory")
      end

      # Search this door's readable documents; returned paths keep their
      # binding names so a match can be passed directly to read or edit.
      def grep(pattern:, path: nil, ignore_case: false, limit: nil)
        fields = { "pattern" => pattern, "path" => path, "ignore_case" => ignore_case, "limit" => limit }.compact
        answer = @dispatch.call("#{@path}/grep", method: :post, body: { "memory" => fields })
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
      # conversation to bump — every next turn reads `user/` live.
      #
      # A skill at `user/skills/<name>` or `workspace/skills/<name>` takes
      # `description:` — REQUIRED there (`skill_description_required`),
      # refused on any other path (`memory_description_invalid`), the name
      # under the skill grammar (`skill_name_invalid`), never on the
      # conversation rung (`skill_scope_unavailable`). The description is
      # sent only when given.
      def write(document_path, content, expected_public_id:, expected_lock_version:, description: nil)
        fields = { "path" => document_path, "content" => content,
                   "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }
        fields["description"] = description unless description.nil?
        shape(MemoryDocument, @dispatch.call(path, method: :post, success: 201, body: { "memory" => fields }), "memory")
      end

      # Replace one exact text occurrence at the version the caller read.
      # Conflicts surface unchanged; this never reads or retries a newer row.
      def edit(path:, old_text:, new_text:, expected_public_id:, expected_lock_version:)
        fields = { "path" => path, "old_text" => old_text, "new_text" => new_text,
                   "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version }
        shape(MemoryDocument, @dispatch.call("#{@path}/edit", method: :post, body: { "memory" => fields }), "memory")
      end

      # Gone for good — no history, no recycle bin. A conversation forked
      # from this one keeps its own copy; this does not reach it. The required
      # identity/version pair also refuses deletion of a recreated document.
      def delete(document_path, expected_public_id:, expected_lock_version:)
        @dispatch.call("#{path}/delete", method: :post, success: 204,
          body: { "memory" => { "path" => document_path,
                               "expected_public_id" => expected_public_id, "expected_lock_version" => expected_lock_version } })
        nil
      end
    end
  end
end
