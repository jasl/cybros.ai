module Rho
  module Acp
    class Agent
      # THE FRAMES → `session/update`. The frames
      # are what `HostFollower` fans — every events-feed item, handled or not,
      # plus the transcript pump's `text_delta`/`reasoning_delta`/
      # `stream_reset` and the `round`/`call` rows relayed whole — handed
      # here by `TurnFollow`'s `on_frame` BEFORE the settle machine reads
      # them. One `Mapping` per follow, over the turn's `TurnState`, which
      # outlives the follow (a re-join after an ask keeps the counters).
      #
      #   snapshot (join)        seeds the task table; on a RE-JOIN emits only
      #                          the reply bytes past `emitted_text`
      #                          (`text_length` vs the bound, the
      #                          `StreamPrinter#partial` arithmetic)
      #   text_delta             agent_message_chunk, messageId "<turn>:<n>"
      #   reasoning_delta        agent_thought_chunk
      #   stream_reset           nothing on the wire; n += 1, the emitted
      #                          count starts over (a replacement never
      #                          merges into the discarded reply — Zed
      #                          merges chunks whose ids match or are absent)
      #   task_status tool_task  FIRST sight: ONE `Core#task` read →
      #                          tool_call {title, kind, status, rawInput,
      #                          locations, diffs} — a call already settled
      #                          at first sight (the follow attached late)
      #                          is then completed as a live client saw it:
      #                          tool_call_update {status, content: [the
      #                          output preview]}; later: tool_call_update
      #                          {status}; `todo_write` completed → plan
      #   call (settled row)     tool_call_update {status, content: [the
      #                          output preview]} — no second read
      # task_status ask nothing
      #   everything else        nothing on the wire (`usage` exists, but
      #                          `UsageUpdate.size` is required and no kernel
      #                          fact carries a context window — never
      #                          invented); `conversation_ended` marks the
      # session ended (-32002 from then on)
      #
      # A frame naming another loop than the turn's moves nothing (the
      # kernel's between-turn summary runs on its own loop). Nothing here
      # raises into the follow: a frame that cannot be mapped is logged and
      # the follow goes on.
      class Mapping
        TOOL_TASK = "tool_task".freeze
        ASK = "ask".freeze
        TODO_TOOL = "todo_write".freeze
        WRITE_TOOL = "write".freeze
        EDIT_TOOL = "edit".freeze

        # The ACP `ToolKind` of rho's tools; every
        # other name — `skill`, `memory_*`, `spawn`, `task`, `code`,
        # `send`, `mcp__*`, `delegate_agent`, `checkpoints` — is `other`.
        KIND = {
          "read" => "read", "ls" => "read", "read_process" => "read", "list_processes" => "read",
          "files_bytes" => "read", "browser_snapshot" => "read", "browser_screenshot" => "read",
          "grep" => "search", "find" => "search",
          "write" => "edit", "edit" => "edit",
          "bash" => "execute", "start_process" => "execute", "stop_process" => "execute", "checkpoint_restore" => "execute",
          "web_fetch" => "fetch", "browser_navigate" => "fetch",
          "todo_write" => "think",
        }.freeze

        # The kernel's task statuses → `ToolCallStatus`.
        STATUS = {
          "waiting" => "pending", "needs_approval" => "pending",
          "dispatched" => "in_progress", "running" => "in_progress",
          "completed" => "completed",
          "failed" => "failed", "timed_out" => "failed", "uncertain" => "failed", "canceled" => "failed",
          "skipped" => "failed",
        }.freeze

        # The argument the title quotes, in preference order (a grep quotes
        # its pattern before its path), then any string.
        TITLE_KEYS = %w[command pattern query url path prompt text name skill].freeze
        # The path-shaped arguments that become `locations`.
        PATH_KEYS = %w[path file directory dir].freeze

        def self.kind_of(tool_name) = KIND.fetch(tool_name.to_s, Acp::Methods::ToolKind::OTHER)

        def self.status_of(status) = STATUS.fetch(status.to_s, Acp::Methods::ToolCallStatus::IN_PROGRESS)

        attr_reader :state

        def initialize(agent:, session:, core:, state:)
          @agent = agent
          @session = session
          @core = core
          @state = state
        end

        # `TurnFollow`'s `on_frame`.
        def frame(type, payload)
          case type
          when "snapshot" then snapshot(payload)
          when "text_delta" then chunk(Acp::Methods::SessionUpdate::AGENT_MESSAGE_CHUNK, payload["text"])
          when "reasoning_delta" then thought(payload["text"])
          when "stream_reset" then reset
          when "task_status" then task_status(payload)
          when "call" then call(payload)
          when "conversation_ended" then @session.ended = true
          else nil
          end
        rescue StandardError => error
          @agent.say("a #{type} frame was not mapped (#{error.class}: #{error.message})")
        end

        # ---- the reply ----

        # A chunk of the reply, counted against the daemon's accumulator.
        def chunk(kind, text)
          text = text.to_s
          return if text.empty?

          @state.transcript.accumulate(text) if kind == Acp::Methods::SessionUpdate::AGENT_MESSAGE_CHUNK
          update(kind, "content" => { "type" => "text", "text" => text }, "messageId" => @state.message_id)
        end

        # THE MODEL'S QUESTION without a form, streamed under the
        # reply's message id but NEVER counted: the daemon's accumulator
        # holds no byte of it, and a count that included it would cut the
        # re-join's `partial` short by its length — the reply's first bytes
        # after the answer, lost.
        def question(text)
          text = text.to_s
          return if text.empty?

          update(Acp::Methods::SessionUpdate::AGENT_MESSAGE_CHUNK,
            "content" => { "type" => "text", "text" => text }, "messageId" => @state.message_id)
        end

        private

          def thought(text)
            text = text.to_s
            return if text.empty?

            update(Acp::Methods::SessionUpdate::AGENT_THOUGHT_CHUNK,
              "content" => { "type" => "text", "text" => text }, "messageId" => @state.message_id)
          end

          def reset
            @state.message += 1
            @state.transcript.reset
          end

          # ---- the join ----

          def snapshot(payload)
            return if payload["turn"] && payload["turn"] != @state.turn

            @state.run_public_id ||= payload["run_public_id"]
            partial(payload["text"], payload["text_length"])
            Array(payload["tasks"]).each { |task| task_status(task) }
          end

          # The bytes past what this turn already sent: `length` is every
          # byte accumulated since the last reset, more than `text` holds
          # once the reply passed the daemon's bound.
          def partial(text, length)
            return if text.nil?

            shown = @state.transcript.replace_snapshot(text.to_s, length: length).scrub
            @state.message += 1 if @state.transcript.replaced?
            return if shown.empty?

            update(Acp::Methods::SessionUpdate::AGENT_MESSAGE_CHUNK,
              "content" => { "type" => "text", "text" => shown }, "messageId" => @state.message_id)
          end

          # ---- the calls ----

          def task_status(payload)
            key = payload["task_key"]
            return if key.nil? || payload["kind"] == ASK
            return unless payload["kind"] == TOOL_TASK || @state.tasks.key?(key)
            return if foreign?(payload)

            status = payload["status"].to_s
            row = @state.tasks[key]
            if row.nil?
              first_sight(key, status)
            elsif row.status != status
              row.status = status
              update(Acp::Methods::SessionUpdate::TOOL_CALL_UPDATE,
                "toolCallId" => call_id(key), "status" => Mapping.status_of(status))
            end
            plan(key) if status == "completed" && @state.tasks[key]&.tool_name == TODO_TOOL
          end

          def foreign?(payload)
            run_id = payload["run_public_id"]
            !!(run_id && @state.run_public_id && run_id != @state.run_public_id)
          end

          # ONE read, the tool_call, the row remembered.
          def first_sight(key, status)
            detail = read_task(key)
            name = detail["tool_name"].to_s
            input = Hash.try_convert(detail["tool_input"]) || {}
            row = ToolCall.new(title: title_of(name, input, key), kind: Mapping.kind_of(name), input: input,
              status: status, tool_name: name)
            @state.tasks[key] = row
            document = {
              "toolCallId" => call_id(key), "title" => row.title, "kind" => row.kind,
              "status" => Mapping.status_of(status), "rawInput" => input,
            }
            locations = locations_of(input)
            document["locations"] = locations unless locations.empty?
            diffs = diffs_of(name, input)
            document["content"] = diffs unless diffs.empty?
            update(Acp::Methods::SessionUpdate::TOOL_CALL, document)
            settle_late(key, status, detail)
          end

          # A call that settled before the follow attached: its settled-call
          # frame went by unseen, so the preview it carried comes off the
          # task read, and the client ends on the same two frames — the call
          # with its diffs, the completion with its preview — a live client
          # got.
          def settle_late(key, status, detail)
            preview = String.try_convert(detail["output_preview"])
            return unless settled?(status) && preview && !preview.empty?

            update(Acp::Methods::SessionUpdate::TOOL_CALL_UPDATE,
              "toolCallId" => call_id(key), "status" => Mapping.status_of(status), "content" => preview_content(preview))
          end

          def settled?(status)
            [Acp::Methods::ToolCallStatus::COMPLETED, Acp::Methods::ToolCallStatus::FAILED].include?(Mapping.status_of(status))
          end

          # The output preview as the call's content: what a completion
          # update replaces the diffs with.
          def preview_content(preview) = [{ "type" => "content", "content" => { "type" => "text", "text" => preview } }]

          def read_task(key)
            return {} if @state.run_public_id.nil?

            @core.task(@state.run_public_id, key)
          rescue Rho::Error => error
            @agent.say("the task #{key} could not be read (#{error.message})")
            {}
          end

          def title_of(name, input, key)
            name = key if name.empty?
            argument = TITLE_KEYS.filter_map { |field| String.try_convert(input[field]) }.find { |value| !value.empty? } ||
              input.values.filter_map { |value| String.try_convert(value) }.find { |value| !value.empty? }
            return name if argument.nil?

            "#{name} #{argument.lines.first.to_s.chomp}"
          end

          # Every path-shaped argument, absolute against the root of the
          # moment; a non-string is no location.
          def locations_of(input)
            PATH_KEYS.filter_map do |field|
              value = String.try_convert(input[field])
              next if value.nil? || value.empty?

              { "path" => absolute(value) }
            end
          end

          def absolute(path) = File.expand_path(path, @session.root)

          # `write` adds one diff of the whole content; `edit` one per entry.
          def diffs_of(name, input)
            path = String.try_convert(input["path"])
            return [] if path.nil?

            case name
            when WRITE_TOOL
              content = String.try_convert(input["content"])
              return [] if content.nil?

              [{ "type" => "diff", "path" => absolute(path), "newText" => content }]
            when EDIT_TOOL
              Array(input["edits"]).filter_map do |edit|
                edit = Hash.try_convert(edit)
                content = String.try_convert(edit&.fetch("newText", nil))
                next if content.nil?

                { "type" => "diff", "path" => absolute(path), "oldText" => edit["oldText"], "newText" => content }.compact
              end
            else []
            end
          end

          # The settled row: the status, the preview; the title kept.
          def call(payload)
            row = Hash.try_convert(payload.dig("payload", "call")) || {}
            key = row["task_key"]
            return if key.nil?
            return if foreign?(payload)

            name = row["name"].to_s
            status = row["is_error"] ? Acp::Methods::ToolCallStatus::FAILED : Acp::Methods::ToolCallStatus::COMPLETED
            document = { "toolCallId" => call_id(key), "status" => status }
            preview = String.try_convert(row["output_preview"])
            document["content"] = preview_content(preview) if preview && !preview.empty?
            known = @state.tasks[key]
            if known
              known.status = row["is_error"] ? "failed" : "completed"
              update(Acp::Methods::SessionUpdate::TOOL_CALL_UPDATE, document)
            else
              @state.tasks[key] = ToolCall.new(title: name, kind: Mapping.kind_of(name), input: {}, status: known,
                tool_name: name)
              update(Acp::Methods::SessionUpdate::TOOL_CALL, document.merge("title" => name, "kind" => Mapping.kind_of(name)))
            end
          end

          # The checklist's read → the plan whole (the spec's replace rule;
          # rho's statuses are already `pending|in_progress|completed`).
          def plan(key)
            detail = read_task(key)
            return if detail.dig("result", "is_error")

            todos = Array.try_convert(detail.dig("tool_input", "todos"))
            return if todos.nil?

            entries = todos.filter_map do |todo|
              todo = Hash.try_convert(todo)
              next if todo.nil?

              { "content" => todo["content"].to_s, "priority" => "medium", "status" => todo["status"].to_s }
            end
            update(Acp::Methods::SessionUpdate::PLAN, "entries" => entries)
          end

          def call_id(key) = "#{@state.run_public_id}:#{key}"

          def update(kind, fields)
            @agent.connection.notify(Acp::Methods::SESSION_UPDATE,
              "sessionId" => @session.id,
              "update" => { Acp::Methods::SESSION_UPDATE_DISCRIMINATOR => kind }.merge(fields))
          rescue Closed
            nil
          end
      end
    end
  end
end
