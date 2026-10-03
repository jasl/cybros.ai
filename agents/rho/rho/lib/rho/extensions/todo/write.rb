module Rho
  module Extensions
    module Todo
      # THE LIST AS A VALUE: the model's items, and the ONE rendered shape
      # the model (the memory block), the person (`rho watch`) and the webui
      # read — hermes' markers, one item per line. The JSON lives nowhere
      # but the kernel's task row; a pure build over arguments the runner
      # already validated against the tool's SCHEMA, so nothing
      # here judges a shape or a plan: two `in_progress` items are the
      # model's plan, not a refusal — the kernel interprets no argument, and
      # neither does rho.
      class List
        Item = Data.define(:content, :status)

        MARKERS = { "pending" => "- [ ] ", "in_progress" => "- [>] ", "completed" => "- [x] " }.freeze
        COMPLETED = "completed".freeze

        attr_reader :items

        def self.of(todos)
          new(Array(todos).map { |todo| Item.new(content: todo.fetch("content"), status: todo.fetch("status")) })
        end

        def initialize(items)
          @items = items.freeze
        end

        # A checklist is one item per line: a newline inside a content
        # becomes a space.
        def render
          items.map { |item| "#{MARKERS.fetch(item.status)}#{item.content.gsub(/\r\n|\r|\n/, " ")}" }.join("\n")
        end

        def counts = { "items" => items.length, "completed" => items.count { |item| item.status == COMPLETED } }

        def empty? = items.empty?

        # Non-empty and every item completed: the shape that CLEARS the
        # document (claude-code clears on all-completed; no reference
        # re-shows a finished list).
        def finished? = !empty? && items.all? { |item| item.status == COMPLETED }
      end

      # THE ONE TOOL, `todo_write`: the whole list in, one whole-document
      # write (or the delete that clears it) through the conversation's
      # memory door, a receipt of counts out — never the list, which the
      # next turn's memory block re-reads (the coding pair's receipt with hermes' counts).
      class Write
        NAME = "todo_write".freeze
        # The tool description is the model-facing home of this workflow. It explains whole-list
        # replacement, when to update statuses, and where later turns see the list; no separate
        # prompt fragment duplicates it.
        DESCRIPTION = <<~TEXT.strip.freeze
          Track the steps of a multi-step task as a todo list the person can see. Send the WHOLE list each time; it replaces the previous one. Each item has a content (the step, specific and actionable) and a status: pending, in_progress or completed. Keep exactly one item in_progress while work remains: set a step in_progress before you start it, and mark it completed immediately when the work is verified done — never on intent, never batched later. If a step is blocked or only partly done, keep it in_progress and add an item for what blocks it. When the plan changes, rewrite the list before continuing. Use it when the work has three or more steps, when the person asked for several things at once, or when they ask for a plan or todos; do not use it for a single step you can just do. The list is kept with this conversation and shown to you again on later turns in your memory block, under conversation/todo.md; change it only through this tool, never with memory_write. An empty list, or a list with every item completed, clears it.

          Example: {"todos": [{"content": "Add the CLI entry", "status": "completed"}, {"content": "Parse the input file", "status": "in_progress"}, {"content": "Write the tests", "status": "pending"}]}
        TEXT
        # THE WHOLE SHAPE: the runner validates every call against it before the handler, so
        # `minLength: 1`, the enum, `required` and the closed properties are the one validator
        # of the list.
        SCHEMA = {
          "type" => "object",
          "properties" => {
            "todos" => {
              "type" => "array",
              "description" => "The whole list, in order.",
              "items" => {
                "type" => "object",
                "properties" => {
                  "content" => { "type" => "string", "minLength" => 1, "description" => "The step, specific and actionable." },
                  "status" => { "type" => "string", "enum" => %w[pending in_progress completed] },
                },
                "required" => %w[content status],
                "additionalProperties" => false,
              },
            },
          },
          "required" => %w[todos],
          "additionalProperties" => false,
        }.freeze
        # Whole-list replacement is intrinsically idempotent; `destructive`
        # because a successful replacement removes the previous list.
        EFFECT_PROFILE = { "kind" => "write", "destructive" => true, "world" => "closed",
                           "idempotency" => "intrinsic", "reconciliation" => "lookup" }.freeze
        TIMEOUT_MS = 30_000

        NO_CONVERSATION = "this loop has no conversation, so it keeps no todo list; the list you sent stays in " \
                          "this call's arguments".freeze
        NO_PLANE = "no member plane: this rho holds no adopted workspace, so it cannot write the todo list".freeze
        WRITE_REFUSED = "the todo list could not be written: %s".freeze
        CLEARED = "Todo list cleared.".freeze

        class << self
          attr_reader :member_plane, :log

          # Bound at registration (the Compaction pattern): the plane callable
          # and the daemon's log, each nil under a loader with no daemon.
          def bind(member_plane:, log:)
            @member_plane = member_plane
            @log = log
          end
        end

        def initialize(env:)
          @env = env
        end

        def call(args)
          list = List.of(args.fetch("todos"))
          context = Rho::Runner::ExecutionContext.current
          conversation = context&.conversation_public_id
          return Rho::Runner::Result.error(NO_CONVERSATION) if conversation.nil?

          plane = self.class.member_plane&.call(host_public_id: conversation, workspace_public_id: context&.workspace_public_id)
          return Rho::Runner::Result.error(NO_PLANE) if plane.nil?

          door = plane.client.workspace(plane.workspace_public_id).conversation(conversation).memory
          document = current_document(door)
          list.empty? || list.finished? ? clear(door, conversation, document) : write(door, conversation, list, document)
        rescue CybrosAgent::Error => error
          # A kernel refusal relays as text under its own code — `memory_full`,
          # `memory_document_too_large`, `memory_content_invalid`,
          # `memory_scope_unavailable`, the door's `memory_overridden` 409,
          # `conversation_archived`, `not_found` — as `completed, is_error`.
          Rho::Runner::Result.error(format(WRITE_REFUSED, error.code || error.message))
        end

        private

          # Execute this replacement against the document present now. CAS protects
          # the read-to-write interval, not the model's earlier reasoning. Never retry.
          def current_document(door)
            door.read(Todo::DOCUMENT)
          rescue CybrosAgent::Api::NotFound => error
            raise unless error.code == "memory_not_found"

            nil
          end

          def write(door, conversation, list, document)
            text = list.render
            door.write(Todo::DOCUMENT, text, expected_public_id: document&.public_id,
              expected_lock_version: document&.lock_version)
            counts = list.counts
            self.class.log&.info("todo.written", conversation: conversation, items: counts.fetch("items"),
              completed: counts.fetch("completed"), bytes: text.bytesize)
            Rho::Runner::Result.ok(receipt(counts))
          end

          def clear(door, conversation, document)
            if document
              door.delete(Todo::DOCUMENT, expected_public_id: document.public_id,
                expected_lock_version: document.lock_version)
            end
            self.class.log&.info("todo.cleared", conversation: conversation)
            Rho::Runner::Result.ok(CLEARED)
          end

          def receipt(counts)
            items = counts.fetch("items")
            "Todo list updated: #{items} item#{items == 1 ? "" : "s"}, #{counts.fetch("completed")} completed."
          end
      end
    end
  end
end
