module NexusDoubles
  class FakeAgentApi
    private

      def respond(status, body)
        CybrosAgent::Response.new(status: status, headers: {}, body: body)
      end

      # The streamed read: a listed id writes its bytes (or its
      # representation of the named kind) into the sink and answers a
      # bodiless 200 with a strong tag (the transport's own shape); an
      # unlisted id is 404, a listed one with no representation of that
      # kind is the typed refusal.
      def upload_bytes_response(path, sink)
        public_id, kind = path.match(%r{\A/agent_api/v1/uploads/([^/]+)/(bytes|thumbnail|preview)\z})&.captures
        source = public_id && @upload_bytes[public_id]
        return respond(404, { "error" => { "code" => "not_found", "message" => "no such upload" } }) if source.nil?

        bytes = kind == "bytes" ? source : @upload_representations.dig(kind, public_id)
        if bytes.nil?
          return respond(404, { "error" => { "code" => "representation_unavailable", "message" => "no #{kind}" } })
        end

        sink.write(bytes)
        CybrosAgent::Response.new(status: 200, headers: { "content-type" => "image/png", "etag" => %("#{kind}-#{public_id}") },
          body: nil)
      end

      def upload_response(form)
        part = form.fetch(:upload).fetch(:file)
        @uploads << { filename: part.filename, byte_size: part.size, bytes: part.read }
        respond(201, { "upload" => {
          "public_id" => "up-#{@uploads.length}", "filename" => part.filename, "content_type" => "image/png",
          "byte_size" => part.size, "created_at" => "2026-09-12T00:00:00Z",
        } })
      end

      # The single discovery read: an id nobody listed conceals as absence,
      # the plane's rule.
      def executor_response(method, path, credential)
        return nil unless method == :get && credential == MEMBER_TOKEN
        public_id = path[%r{\A/agent_api/v1/executors/([^/]+)\z}, 1]
        return nil if public_id.nil?

        row = @executors.find { |candidate| candidate.fetch("public_id") == public_id }
        return respond(404, { "error" => { "code" => "not_found", "message" => "no executor #{public_id}" } }) if row.nil?

        respond(200, { "executor" => row })
      end

      # THE HANDOFF DOOR on either host: a target nobody listed is 404
      # `runner_not_found`; a listed one that is not a runner too; the same
      # id is the plain 200 (`runner_unchanged`, no receipt); a scripted
      # Response refuses instead. The binding moves, and the host document
      # reads it back.
      def handoff_response(host_public_id, body)
        executor = body.dig("runner", "executor_public_id")
        @handoffs << [host_public_id, executor]
        return @handoff unless @handoff == :accept

        row = @executors.find { |candidate| candidate.fetch("public_id") == executor }
        if row.nil? || row.fetch("kind") != "runner"
          return respond(404, { "error" => { "code" => "runner_not_found", "message" => "no runner #{executor}" } })
        end

        @runner_bindings[host_public_id] = executor
        yield
      end

      # The `runner` read: the binding with the presence the
      # listed document carries; nil (a null on the conversation document,
      # absent on the loop's) when none.
      def runner_binding(host_public_id)
        executor = @runner_bindings[host_public_id]
        return nil if executor.nil?

        row = @executors.find { |candidate| candidate.fetch("public_id") == executor }
        # A BOUND RUNNER ALWAYS HAS A PRESENCE on the kernel's document, even
        # one this double was never handed a row for; the SDK reads it
        # strictly, so the binding answers the kernel's shape either way.
        { "executor_public_id" => executor, "display_name" => row&.fetch("display_name", nil),
          "presence" => row&.fetch("presence", nil) || "offline",
          "last_seen_at" => row&.fetch("last_seen_at", nil) }.compact
      end

      def workspace_list(params)
        @workspace_list_params << params
        rows = @workspaces
        dedicated = params&.dig("dedicated_to_current_agent") == true
        rows = rows.select { |workspace| workspace.fetch(:dedicated, true) == dedicated &&
          (!dedicated || workspace.fetch(:own, true)) }
        { "workspaces" => rows.map { |workspace| workspace_row(workspace) },
          "pagination" => { "next_after" => nil } }
      end

      def workspace_create_response(body, headers)
        @workspace_creates << { body: body, headers: headers }
        return @workspace_create unless @workspace_create == :accept

        @workspace_sequence += 1
        row = {
          public_id: "0199-workspace-#{@workspace_sequence}",
          name: body.dig("workspace", "name"),
          dedicated: true,
        }
        @workspaces << row
        respond(201, { "workspace" => workspace_document(row) })
      end

      # The singular read, as the kernel answers it: the row when this
      # agent may see it (the steward's access — a row the test never
      # stocked is `not_found`, never a 403 that admits it exists).
      def workspace_fetch_response(method, path, credential)
        return nil unless method == :get && credential == MEMBER_TOKEN

        public_id = path[%r{\A/agent_api/v1/workspaces/([^/]+)\z}, 1]
        return nil if public_id.nil?

        @workspace_fetches << public_id
        row = @workspaces.find { |workspace| workspace.fetch(:public_id) == public_id }
        return respond(404, { "error" => { "code" => "not_found", "message" => "Not found" } }) if row.nil?

        respond(200, { "workspace" => workspace_document(row) })
      end

      # The Full projection the singular doors answer with.
      def workspace_document(row)
        workspace_row(row).merge(
          "metadata" => {}, "tool_provider_overrides" => {},
          "owner" => { "public_id" => "0199-steward", "display_name" => "Steward" },
          "creator" => { "public_id" => @user_public_id, "display_name" => "Helper", "kind" => "agent" },
        )
      end

      def workspace_row(workspace)
        {
          "public_id" => workspace[:public_id],
          "name" => workspace[:name],
          "access_mode" => workspace.fetch(:access_mode, "private"),
          "state" => "active",
          "dedicated" => workspace.fetch(:dedicated, true),
          "lock_version" => 0,
          "archived_at" => nil,
          "created_at" => "2026-07-30T00:00:00Z",
          "updated_at" => "2026-07-30T00:00:00Z",
        }
      end

      def profile(configuration = nil)
        {
          "member" => {
            "public_id" => @user_public_id, "handle" => "helper", "kind" => "agent", "role" => "member",
            "display_name" => "Helper",
          },
          "credential" => { "plane" => "member", "expires_at" => nil },
          "configuration" => configuration || undeclared_configuration,
          # No address block at all: the member plane never answers with the
          # caller's own address, and a profile has only its own.
          "measured_at" => "2026-07-26T00:00:00Z",
        }
      end

      def undeclared_configuration
        { "tool_definitions" => [], "approval_mode" => nil, "approval_rules" => nil,
          "prompt_mechanism" => nil, "prompt_template" => nil, "compaction_policy" => nil }
      end

      def unauthorized = { "error" => { "code" => "unauthorized", "message" => "Unauthorized" } }

      # THE SLOT WRITE, read back as the kernel's presenter renders it: a
      # whole replacement, 200 whether first or later, the version counting
      # the writes to this fake.
      def prompt_document_response(slot, body)
        @prompt_document_writes << [slot, body]
        return @prompt_document unless @prompt_document == :accept

        content = body.dig("prompt_document", "content").to_s
        respond(200, { "prompt_document" => {
          "slot" => slot, "role" => body.dig("prompt_document", "role") || "system",
          "bytesize" => content.bytesize, "version" => @prompt_document_writes.count { |written, _| written == slot },
          "written_at" => "2026-09-08T00:00:00Z", "content" => content,
        } })
      end

      def prompt_document_delete_response(slot)
        @prompt_document_deletes << slot
        held = @prompt_document_writes.any? { |written, _| written == slot } ||
          @prompt_documents.any? { |row| row["slot"] == slot }
        return respond(204, nil) if held

        respond(404, { "error" => { "code" => "prompt_document_not_found", "message" => "No #{slot} is written" } })
      end

      # One slot read whole; a slot this profile's door cannot hold is the
      # kernel's `prompt_slot_unavailable`, typed 422.
      def prompt_document_read_response(method, path, credential)
        slot = path[%r{\A/agent_api/v1/profile/prompt_documents/([^/]+)\z}, 1]
        return nil unless method == :get && slot && credential == MEMBER_TOKEN

        row = @prompt_documents.find { |candidate| candidate["slot"] == slot }
        return respond(200, { "prompt_document" => row }) if row

        respond(422, { "error" => { "code" => "prompt_slot_unavailable", "message" => "This profile cannot hold #{slot}" } })
      end

      # The three doors' stores: `profile`, `workspace`, and a conversation's
      # by its id (the room's own door).
      MEMORY_DOORS = %r{\A/agent_api/v1/(?:profile|workspaces/[^/]+(?:/conversations/(?<conversation>[^/]+))?)/memory(?<verb>/show|/delete)?\z}

      # The three doors' four verbs over one store each, with the writer's
      # words in the kernel's order.
      def memory_response(method, path, credential, body)
        match = MEMORY_DOORS.match(path)
        return nil unless match && credential == MEMBER_TOKEN

        store = @memory[match[:conversation] || (path.include?("/workspaces/") ? "workspace" : "profile")]
        document = body && body.fetch("memory", {})
        case [method, match[:verb]]
        when [:get, nil] then respond(200, { "memory" => store.values.sort_by { |row| row["path"] }.map { |row| row.except("content") } })
        when [:post, "/show"] then memory_read_response(store, document.fetch("path"))
        when [:post, "/delete"]
          memory_delete_response(store, document)
        when [:post, nil] then memory_write_response(store, document)
        else nil
        end
      end

      def memory_read_response(store, path)
        row = store[path]
        row ? respond(200, { "memory" => row }) : memory_refusal("memory_not_found", 404)
      end

      def memory_write_response(store, document)
        @memory_writes << document
        path, description = document.values_at("path", "description")
        existing = store[path]
        return memory_refusal("stale_object", 409) unless memory_matches?(existing, document)

        _scope, name = path.to_s.split("/", 2)
        if name.to_s.start_with?("skills/")
          skill = name.delete_prefix("skills/")
          return memory_refusal("skill_name_invalid") unless skill.match?(/\A[a-z0-9](?:-?[a-z0-9])*\z/)
          return memory_refusal("skill_scope_unavailable") if path.start_with?("conversation/")
          return memory_refusal("skill_description_required") if description.to_s.strip.empty?
        elsif !description.nil?
          return memory_refusal("memory_description_invalid")
        end
        store[path] = memory_row(path, document.fetch("content"), description,
          public_id: existing ? existing.fetch("public_id") : SecureRandom.uuid_v7,
          lock_version: existing ? existing.fetch("lock_version") + 1 : 0)
        respond(201, { "memory" => store[path] })
      end

      def memory_delete_response(store, document)
        return memory_refusal("invalid_request", 400) if document.fetch("expected_public_id").nil?
        return memory_refusal("stale_object", 409) unless memory_matches?(store[document.fetch("path")], document)

        store.delete(document.fetch("path"))
        respond(204, nil)
      end

      def memory_matches?(row, document)
        expected = document.fetch("expected_public_id"), document.fetch("expected_lock_version")
        expected == (row ? row.values_at("public_id", "lock_version") : [nil, nil])
      end

      def memory_row(path, content, description, public_id: SecureRandom.uuid_v7, lock_version: 0)
        { "path" => path, "public_id" => public_id, "lock_version" => lock_version,
          "bytesize" => content.bytesize, "description" => description, "content" => content,
          "written_at" => "2026-09-15T00:00:00Z" }
      end

      def memory_refusal(code, status = 422)
        respond(status, { "error" => { "code" => code, "message" => "Refused: #{code}" } })
      end

      # Read back exactly as declared, the way the kernel answers the PUT.
      # A CALLABLE `configuration:` runs BEFORE the record: the kernel
      # applies a PUT when its bytes arrive, so a fake that parks here (a
      # `sleep` yields the reactor fiber) records two concurrent
      # declarations in the order the kernel would apply them — the
      # declaring gate's pin (`daemon/grants_test`). It answers `:accept`
      # or a Response, as the plain form does.
      def configuration_response(body)
        answer = @configuration.respond_to?(:call) ? @configuration.call(body) : @configuration
        @configuration_declarations << body
        return answer unless answer == :accept

        declared = body.fetch("configuration")
        respond(200, profile(declared.merge("tool_definitions" => Array(declared["tool_definitions"]))))
      end

      def claim_response(row, credential)
        key = row.fetch("task_key")
        @claims << key
        if @claim == :taken || row.fetch("claimed", false)
          return respond(409, { "error" => { "code" => "already_claimed", "message" => "taken" } })
        end

        claimed = row.merge("claimed" => true)
        if credential == RUNNER_TOKEN
          @runner_inbox_tasks = @runner_inbox_tasks.map { |candidate| candidate.equal?(row) ? claimed : candidate }
        else
          @inbox_tasks = @inbox_tasks.map { |candidate| candidate.equal?(row) ? claimed : candidate }
        end
        respond(200, { "task" => claimed, "claim" => { "claim_token" => "tok-#{key}", "deadline_at" => nil } })
      end

      def commit_response(key, body)
        @commits << [key, body]
        respond(200, { "task" => { "key" => key, "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => body.fetch("outcome", "completed"),
                                   "on_failure" => "halt", "visibility" => "visible",
                                   "created_at" => "2026-09-07T00:00:00Z" } })
      end

      # Answered with the description, as the kernel does: the served list
      # is not the executor's to read back.
      def announcement_response(body)
        @announcements << body
        return @announcement unless @announcement == :accept

        respond(200, executor)
      end

      def runner_announcement_response(body)
        @runner_announcements << body
        return @announcement unless @announcement == :accept

        respond(200, runner_executor)
      end

      def executor
        {
          "executor" => {
            "public_id" => @executor_public_id, "kind" => "agent_application", "status" => "active",
            "display_name" => "Helper", "presence" => "offline", "credential_epoch" => 1,
          },
          "measured_at" => "2026-07-26T00:00:00Z",
        }
      end

      def runner_executor
        {
          "executor" => {
            "public_id" => @runner_executor_public_id, "kind" => "runner", "status" => "active",
            "display_name" => "Helper", "presence" => "offline", "credential_epoch" => 1,
          },
          "measured_at" => "2026-07-26T00:00:00Z",
        }
      end
  end
end
