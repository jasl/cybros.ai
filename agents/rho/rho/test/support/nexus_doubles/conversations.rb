module NexusDoubles
  class FakeAgentApi
    # The turns index's ceiling (`TurnsController::MAX_LIMIT`).
    TURNS_MAX_LIMIT = 100

    # The window as the kernel cuts it (`Conversation::Timeline#entries`):
    # `after_position` exclusive and ascending, `before_position` exclusive
    # and descending — read back in position order — `limit` rows; the
    # pagination is the page's own bounds.
    def turn_page(window)
      rows = Array(@turns).sort_by { |row| row.fetch("position") }
      rows = rows.reject { |row| row["visibility"] == "hidden" } unless window["include_hidden"].to_s == "true"
      rows = rows.select { |row| row.fetch("position") > Integer(window["after_position"]) } if window["after_position"]
      if window["before_position"]
        rows = rows.select { |row| row.fetch("position") < Integer(window["before_position"]) }.reverse
      end
      rows = rows.first(Integer(window["limit"])) if window["limit"]
      rows = rows.reverse if window["before_position"]
      { "turns" => rows,
        "pagination" => { "before_position" => rows.first&.fetch("position"), "after_position" => rows.last&.fetch("position") } }
    end

    MATERIALIZED_EVENTS = [
      { "public_id" => "ev-1", "sequence" => 1, "cursor" => "c1", "type" => "input_materialized",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-06T00:00:00Z",
        "payload" => { "input_public_id" => "cin-1", "queue_position" => 0, "turn_public_id" => "t-1" } },
      { "public_id" => "ev-2", "sequence" => 2, "cursor" => "c2", "type" => "turn_status",
        "resource" => { "type" => "conversation", "public_id" => "c-1" },
        "occurred_at" => "2026-09-06T00:00:00Z",
        "payload" => { "status" => "running", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" } },
    ].freeze

    # THE CONVERSATION DOORS `rho do`, `rho say` and `rho stop` drive on a
    # conversation host: the create, the input queue, the replay feed and
    # the cancellation — each in the projection the SDK reads strictly.
    def conversation_response(method, path, credential, body, params: nil)
      return nil unless credential == MEMBER_TOKEN

      if method == :post && path.match?(%r{\A/agent_api/v1/workspaces/[^/]+/conversations\z})
        @conversation_creates << body
        public_id = "c-#{@conversation_creates.length}"
        @runner_bindings[public_id] = body.dig("conversation", "runner_executor_public_id")
        # The answerer a create named; unnamed is the creator.
        @answerers[public_id] = body.dig("conversation", "answering_user_public_id")
        @access[public_id] = body.dig("conversation", "access") if body.dig("conversation", "access")
        return respond(201, { "conversation" => conversation_row(public_id) })
      end
      if method == :get && path.match?(%r{\A/agent_api/v1/workspaces/[^/]+/conversations\z})
        rows = params && params["side"] == "1" ? @conversation_list.select { |row| row["side"] } : @conversation_list.reject { |row| row["side"] }
        return respond(200, { "conversations" => rows, "pagination" => { "next_after" => nil } })
      end

      conversation = path[%r{\A/agent_api/v1/workspaces/[^/]+/conversations/([^/]+)}, 1]
      return nil if conversation.nil?

      stored = store_entry_response(method, path, conversation, body, params)
      return stored if stored
      if method == :get && path.end_with?("/conversations/#{conversation}/children")
        return respond(200, { "conversations" => @children[conversation], "pagination" => { "next_after" => nil } })
      end

      if method == :post && path.end_with?("/forks")
        @forks << [conversation, body]
        return @fork if @fork.is_a?(CybrosAgent::Response)

        # The child copies the parent's binding (the two facts a rewind compares ride one answer), and the fork point's `world` is the
        # scripted one, else `untouched`.
        child = "#{conversation}-side"
        @runner_bindings[child] = @runner_bindings[conversation] || @conversation_runner
        @store_entries[child] = Marshal.load(Marshal.dump(@store_entries[conversation]))
        stock_conversation(child, side: body.fetch("fork").fetch("side", false))
        return respond(201, { "conversation" => conversation_row(child, side: true),
                              "world" => @fork_world || { "status" => "untouched" } })
      end
      if method == :get && path.end_with?("/conversations/#{conversation}/turns")
        # The index's own ceiling (`TurnsController::MAX_LIMIT` 100): a wider
        # window is the kernel's `parameter_invalid`, so a verb that asks
        # for more fails here as it fails there.
        window = params || {}
        if window["limit"] && Integer(window["limit"]) > TURNS_MAX_LIMIT
          return respond(400, { "error" => { "code" => "parameter_invalid", "message" => "Invalid parameter: limit" } })
        end

        @turn_windows << window
        return respond(200, turn_page(window))
      end
      if method == :post && (regen_turn = path[%r{/turns/([^/]+)/regeneration\z}, 1])
        @regenerations << [conversation, regen_turn, body]
        return @regeneration if @regeneration.is_a?(CybrosAgent::Response)

        return respond(202, default_regeneration(regen_turn))
      end
      if method == :delete && path.end_with?("/conversations/#{conversation}")
        @conversation_deletes << conversation
        @conversation_list.reject! { |row| row.fetch("public_id") == conversation }
        return respond(204, nil)
      end
      # The singular read and THE ACCESS CARRIER'S LATER CHANGE: the
      # PUT is a whole replacement, answered with the document.
      return respond(200, { "conversation" => conversation_row(conversation) }) if
        method == :get && path.end_with?("/conversations/#{conversation}")
      if method == :put && path.end_with?("/conversations/#{conversation}/access")
        @access[conversation] = body.fetch("access")
        return respond(200, { "conversation" => conversation_row(conversation) })
      end
      if method == :get && path.end_with?("/inputs")
        return respond(200, { "inputs" => @input_list, "input_queue" => { "limit" => 16, "held" => @input_list.length } })
      end
      if (input = path[%r{/inputs/([^/]+)\z}, 1])
        if method == :delete
          @input_deletes << input
          return @input_delete.is_a?(CybrosAgent::Response) ? @input_delete : respond(204, nil)
        end
        if method == :patch
          @input_updates << [input, body]
          return @input_update if @input_update.is_a?(CybrosAgent::Response)

          row = @input_list.find { |candidate| candidate["public_id"] == input } || NexusDoubles.input_row(input, "pending")
          return respond(200, { "input" => row.merge("state" => "pending", "blocked_reason" => nil,
            "text" => body.dig("input", "text") || row["text"],
            "deliver_at" => NexusDoubles.scheduled_at(body.fetch("input")) || row["deliver_at"]).compact })
        end
      end

      if method == :put && path.end_with?("/runner")
        return handoff_response(conversation, body) { respond(200, { "conversation" => conversation_row(conversation) }) }
      end

      if method == :post && path.end_with?("/inputs")
        @conversation_inputs << body
        return @conversation_input if @conversation_input.is_a?(CybrosAgent::Response)

        fields = body.fetch("input")
        @conversation_input_ids[conversation] ||= "cin-#{@conversation_inputs.length}"
        return respond(202, { "input" => {
          "public_id" => "cin-#{@conversation_inputs.length}", "queue_position" => @conversation_inputs.length - 1,
          "state" => fields.fetch("delivery_mode", "queue") == "steer" ? "steering" : "pending",
          "kind" => fields.fetch("kind", "direct_reply"), "role" => "user",
          "delivery_mode" => fields.fetch("delivery_mode", "queue"), "text" => fields["text"],
          "origin" => "person", "lock_version" => 0, "created_at" => "2026-09-06T00:00:00Z",
          # The addressee as the door resolved it: the named
          # one, else the conversation's answerer; the author is the fake's user.
          "answering_user_public_id" => fields["answering_user_public_id"] || @answerers[conversation] || @user_public_id,
          "speaker" => NexusDoubles.speaker_row(@user_public_id),
          # NOT BEFORE this time: the kernel
          # answers the row's `deliver_at` on a timed row, absent otherwise.
          "deliver_at" => NexusDoubles.scheduled_at(fields),
        }.compact })
      end
      if method == :get && path.end_with?("/events")
        events =
          case @conversation_events
          when :materialized then materialized_events(conversation)
          # A Queue is the materialized page under the TEST's hand: empty
          # until the test releases it (one push), then the page, on every
          # poll after — a side just forked has nothing to replay, so its
          # follower's first poll must not hand the route a loop "held
          # before" the question.
          when Queue then @conversation_events.empty? ? [] : materialized_events(conversation)
          # A Proc is a page under the test's hand with the test's OWN
          # events: asked on every poll, so a test can stage them — a
          # between-turn summary's item first, the person's turn's later.
          when Proc then @conversation_events.call
          else Array(@conversation_events)
          end
        head = events.map { |event| event.fetch("sequence") }.max || 0
        @conversation_event_head = [@conversation_event_head, head].max if @conversation_event_head
        return respond(200, { "events" => events,
                              "pagination" => { "next_after" => nil,
                                                "watermark" => @conversation_event_head || head } })
      end
      return respond(202, {}) if method == :post && path.end_with?("/cancellation")
      # THE PREVIEW DOOR: the estimate, rendered or not, as the
      # scripted document; the body kept whole for the route's assertion.
      if method == :post && path.end_with?("/context_estimate")
        @context_estimates << { path: path, body: body }
        return @context_estimate if @context_estimate.is_a?(CybrosAgent::Response)

        return respond(200, @context_estimate || { "context_estimate" => {
          "input_tokens" => 0, "tokenizer_exact" => false, "catalog_input_token_limit" => nil,
          "advisory_input_token_limit" => nil, "message_count" => 0, "history" => { "selected" => 0, "skipped" => 0 },
        } })
      end
      # THE DEBUG DOOR on a turn: the deck, then the active
      # candidate's sealed request.
      if @variants && method == :get && path.match?(%r{/turns/[^/]+/variants\z})
        return respond(200, @variants)
      end
      # ONE CANDIDATE'S VIEW STATE: the kernel's PATCH,
      # answered with the deck's row as the door renders it (never active).
      if method == :patch && (patched = path[%r{/turns/[^/]+/variants/([^/]+)\z}, 1])
        @variant_updates << [patched, body]
        row = Array(@variants && @variants["variants"]).find { |candidate| candidate["public_id"] == patched } ||
          { "public_id" => patched, "source" => "inference", "status" => "completed" }
        return respond(200, { "variant" => row.merge("active" => false) })
      end
      if @variant_request && method == :get && path.match?(%r{/variants/[^/]+/request\z})
        return @variant_request.is_a?(CybrosAgent::Response) ? @variant_request : respond(200, @variant_request)
      end
      # The manual compaction door: the summary turn when idle;
      # with a loop-backed reply running, that reply and the round repaired.
      if method == :post && path.end_with?("/compaction")
        @compactions << body
        return respond(202, @compaction) if @compaction

        return respond(202, { "turn" => { "public_id" => "t-#{conversation}-summary", "position" => 4,
                                          "kind" => "compaction_summary", "status" => "running" } })
      end

      nil
    end

    private

      def materialized_events(conversation)
        input_id = @conversation_input_ids[conversation]
        return [] unless input_id

        MATERIALIZED_EVENTS.map do |event|
          payload = event.fetch("payload")
          payload = payload.merge("input_public_id" => input_id) if event.fetch("type") == "input_materialized"
          event.merge("resource" => { "type" => "conversation", "public_id" => conversation }, "payload" => payload)
        end
      end

      # The 202 a regeneration answers: the running turn and a
      # loop-backed sibling with its own loop and its seed round waiting.
      def default_regeneration(turn_public_id)
        { "turn" => { "public_id" => turn_public_id, "status" => "running" },
          "variant" => {
            "public_id" => "v-#{turn_public_id}-regen", "source" => "agent_loop", "status" => "running",
            "active" => false, "agent_loop_public_id" => "al-regen-#{turn_public_id}",
            "rounds" => [{ "task_key" => "r1", "status" => "waiting", "visibility" => "visible" }],
            "world" => { "status" => "untouched" },
          } }
      end

      # THE STORE'S FOUR VERBS on one conversation, as the
      # kernel answers them.
      def store_entry_response(method, path, conversation, body, params)
        return nil unless path.include?("/conversations/#{conversation}/store_entries")

        rows = @store_entries[conversation]
        entry_id = path[%r{/store_entries/([^/]+)\z}, 1]
        return store_collection_response(method, conversation, rows, body) if entry_id.nil?

        row = rows.find { |candidate| candidate["public_id"] == entry_id }
        return respond(404, { "error" => { "code" => "not_found", "message" => "no entry #{entry_id}" } }) if row.nil?

        case method
        when :get then respond(200, { "store_entry" => row })
        when :patch then store_entry_update_response(conversation, entry_id, row, body)
        when :delete
          unless Integer(params.fetch("lock_version")) == row.fetch("lock_version")
            return respond(409, { "error" => { "code" => "stale_object", "message" => "moved" } })
          end

          rows.delete(row)
          respond(204, nil)
        else nil
        end
      end

      def store_collection_response(method, conversation, rows, body)
        case method
        when :get
          respond(200, { "store_entries" => rows.map { |row| row.except("value") }, "pagination" => { "next_after" => nil } })
        when :post
          fields = body.fetch("store_entry")
          @store_entry_creates << [conversation, fields]
          if rows.any? { |row| row["namespace"] == fields["namespace"] && row["key"] == fields["key"] }
            return respond(409, { "error" => { "code" => "key_taken", "message" => "taken" } })
          end

          row = store_entry_row(conversation, fields["namespace"], fields["key"], fields["value"], 0)
          rows << row
          respond(201, { "store_entry" => row })
        else nil
        end
      end

      def store_entry_update_response(conversation, entry_id, row, body)
        @store_entry_updates << [conversation, entry_id, body]
        return @store_entry_update if @store_entry_update.is_a?(CybrosAgent::Response)

        fields = body.fetch("store_entry")
        unless fields["lock_version"] == row.fetch("lock_version")
          return respond(409, { "error" => { "code" => "stale_object", "message" => "moved" } })
        end

        row.merge!("value" => fields["value"], "lock_version" => row.fetch("lock_version") + 1,
          "updated_at" => "2026-09-17T00:00:01Z")
        respond(200, { "store_entry" => row })
      end

      def store_entry_row(conversation, namespace, key, value, lock_version)
        { "public_id" => "se-#{conversation}-#{@store_entries[conversation].length + 1}", "namespace" => namespace,
          "key" => key, "lock_version" => lock_version, "created_at" => "2026-09-17T00:00:00Z",
          "updated_at" => "2026-09-17T00:00:00Z", "value" => value }
      end

      def conversation_row(public_id, side: false)
        # rho creates as itself unless the create named another.
        { "public_id" => public_id, "answering_user_public_id" => @answerers[public_id] || @user_public_id,
          # The parent block when a test stocked one.
          "parent" => (@parents[public_id] && { "public_id" => @parents[public_id] }),
          # The wire says `side` on every row: a side fork's child is one.
          "side" => side,
          # REWIND: a scripted conversation may be busy (a turn
          # running) — the local guard `rho rewind` reads.
          "active_turn_public_id" => @conversation_busy,
          "input_queue" => { "limit" => 16, "held" => 0 },
          "context_revision" => 0, "created_at" => "2026-09-06T00:00:00Z", "updated_at" => "2026-09-06T00:00:00Z",
          "runner" => runner_binding(public_id),
          # THE ACCESS CARRIER, always on the document: what a create
          # named or a later change replaced, else born `full`. The entries
          # render as the kernel renders them — self-describing, the names
          # looked up in the double's principals.
          "access" => access_document(public_id) }
      end

      def access_document(public_id)
        access = @access.fetch(public_id, { "default" => "full", "entries" => [] })
        { "default" => access.fetch("default", "full"),
          "entries" => Array(access["entries"]).map do |entry|
            # An entry names its principal by public id or by handle, the way the kernel resolves either.
            principal = @principals.find do |row|
              row.fetch("public_id") == entry["user_public_id"] ||
                (entry["handle"] && row["handle"] == entry["handle"].delete_prefix("@"))
            end || {}
            { "user_public_id" => principal.fetch("public_id", entry["user_public_id"]),
              "handle" => principal.fetch("handle", entry["handle"]), "kind" => principal.fetch("kind", "human"),
              "display_name" => principal["display_name"], "level" => entry.fetch("level") }
          end }
      end
  end
end
