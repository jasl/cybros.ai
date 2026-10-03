module Rho
  module Gateway
    # External chat controls share one directory and dispatch path. The adapter
    # supplies routing, identity, admission and delivery through its runtime.
    class Commands
      Definition = Data.define(:name, :aliases, :usage, :description, :managed) do
        def initialize(aliases: [], **fields) = super
      end

      DEFINITIONS = [
        Definition.new(name: "help", aliases: ["start"], usage: "help", description: "Show commands and usage", managed: false),
        Definition.new(name: "status", usage: "status [TASK_ID]", description: "Show current work or one accepted task", managed: false),
        Definition.new(name: "queue", usage: "queue [list|edit NUMBER TEXT|reschedule NUMBER TIME|cancel NUMBER]", description: "View or change waiting requests", managed: false),
        Definition.new(name: "remind", usage: "remind in DURATION TEXT | /remind at TIME TEXT", description: "Schedule a one-time reminder in this chat", managed: false),
        Definition.new(name: "job", usage: "job list|show ID|history ID|create once in DURATION TEXT|create every DURATION TEXT|create daily HH:MM TIME_ZONE TEXT|edit ID FIELD VALUE|pause ID|resume ID|cancel ID", description: "Manage independently scheduled tasks", managed: false),
        Definition.new(name: "destinations", usage: "destinations", description: "List chats available for result delivery", managed: true),
        Definition.new(name: "deliver", usage: "deliver TASK_ID DESTINATION", description: "Choose where a task sends its results", managed: true),
        Definition.new(name: "sessions", usage: "sessions [PAGE]", description: "List this chat's conversations", managed: false),
        Definition.new(name: "resume", usage: "resume ID", description: "Return to one of your conversations", managed: false),
        Definition.new(name: "search", usage: "search TEXT|next", description: "Search this chat's saved conversations", managed: false),
        Definition.new(name: "history", usage: "history [before POSITION|hide|show|exclude|include|delete|restore TURN_ID]", description: "Read history or change its visibility", managed: false),
        Definition.new(name: "rename", usage: "rename TITLE", description: "Rename the selected conversation", managed: false),
        Definition.new(name: "archive", usage: "archive [ID]", description: "Archive a saved conversation", managed: false),
        Definition.new(name: "restore", usage: "restore [ID]", description: "Restore an archived conversation", managed: false),
        Definition.new(name: "fork", usage: "fork [POSITION]", description: "Branch history and keep current files", managed: false),
        Definition.new(name: "regenerate", usage: "regenerate [POSITION]", description: "Generate another answer and keep current files", managed: false),
        Definition.new(name: "variants", usage: "variants POSITION", description: "List a turn's answer candidates", managed: false),
        Definition.new(name: "variant", usage: "variant POSITION ID [hide|restore]", description: "Select, hide or restore an answer candidate", managed: false),
        Definition.new(name: "edit", usage: "edit POSITION TEXT", description: "Edit the tail as a new candidate", managed: false),
        Definition.new(name: "undo", usage: "undo", description: "Delete the newest turn", managed: false),
        Definition.new(name: "task", usage: "task pause|resume|retry|abandon [TASK_ID] [TASK_KEY]", description: "Control an accepted task's execution", managed: false),
        Definition.new(name: "transcript", usage: "transcript [TASK_ID] [branch PREFIX] [before CURSOR]", description: "Read the selected task's execution trace", managed: false),
        Definition.new(name: "context", usage: "context", description: "Preview the next request's context", managed: false),
        Definition.new(name: "compact", usage: "compact", description: "Compact the selected conversation", managed: false),
        Definition.new(name: "memory", usage: "memory ls|read PATH|write PATH TEXT|edit JSON|grep TEXT|delete PATH", description: "Manage the selected conversation's memory", managed: false),
        Definition.new(name: "settings", usage: "settings", description: "Show group behavior and your conversation settings", managed: false),
        Definition.new(name: "new", usage: "new", description: "Start a new conversation", managed: false),
        Definition.new(name: "stop", usage: "stop [TASK_ID]", description: "Stop the selected task and its background work", managed: false),
        Definition.new(name: "steer", usage: "steer <text> | /steer TASK_ID <text>", description: "Add instructions to the selected running task", managed: false),
        Definition.new(name: "btw", usage: "btw <question>", description: "Ask a side question without tools", managed: false),
        Definition.new(name: "model", usage: "model [provider/model]", description: "List or choose a model", managed: true),
        Definition.new(name: "workspace", usage: "workspace [list|current|use ID|create NAME]",
          description: "List, choose or create this chat's workspace", managed: true),
        Definition.new(name: "observe", usage: "observe [on|off|status]", description: "View group background context; owner can change it", managed: false),
        Definition.new(name: "mode", usage: "mode [assistant|active|status]", description: "View group participation; owner can change it", managed: false),
        Definition.new(name: "voice", usage: "voice off|voice_only|all", description: "Choose spoken replies, with text kept", managed: true),
        Definition.new(name: "approve", usage: "approve ID", description: "Approve a pending request", managed: true),
        Definition.new(name: "deny", usage: "deny ID", description: "Decline a pending request", managed: true),
        Definition.new(name: "answer", usage: "answer ID your answer", description: "Answer your task's pending question", managed: false),
        Definition.new(name: "access", usage: "access users|chats list|add|remove [ID]", description: "Manage who can interact with the bot", managed: true),
        Definition.new(name: "ignore", usage: "ignore list|add|remove [ID]", description: "Ignore or restore someone's new messages", managed: true),
      ].freeze
      HELP = DEFINITIONS.map { |command| "/#{command.usage} — #{command.description}" }.join("\n").freeze

      TASK_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      # UUID-shaped typos are explicit references too; never send them as an
      # instruction to whichever task happens to be current.
      def self.task_reference?(text) = text.match?(/\A[0-9a-f]{8}-/i)

      def initialize(runtime)
        @runtime = runtime
      end

      def call(update, name, argument)
        command = DEFINITIONS.find { |entry| entry.name == name || entry.aliases.include?(name) }
        return @runtime.reply(update, "Unknown command.\n#{self.class::HELP}") unless command
        if command.managed && (refusal = management_refusal(update))
          return @runtime.reply(update, refusal)
        end

        text = send(command.name, update, argument)
        @runtime.reply(update, text) if text
      end

      private

        def help(_update, _argument) = self.class::HELP

        def management_refusal(update)
          "Only the bot owner can change bot settings or approve tool requests." unless @runtime.owner?(update)
        end

        def access(update, argument) = @runtime.access_command(update, "access", argument)
        def ignore(update, argument) = @runtime.access_command(update, "ignore", argument)
        def destinations(update, argument) = @runtime.destination_list(update, argument)
        def deliver(update, argument) = @runtime.deliver_task(update, argument)
        def job(update, argument) = @runtime.job_command(update, argument)

        def sessions(update, argument) = @runtime.session_list(update, argument)
        def resume(update, argument) = @runtime.resume_session(update, argument)
        def memory(update, argument) = @runtime.memory_command(update, argument)
        def search(update, argument) = @runtime.search_sessions(update, argument)
        def history(update, argument) = @runtime.conversation_command(update, "history", argument)
        def rename(update, argument) = @runtime.conversation_command(update, "rename", argument)
        def archive(update, argument) = @runtime.conversation_command(update, "archive", argument)
        def restore(update, argument) = @runtime.conversation_command(update, "restore", argument)
        def fork(update, argument) = @runtime.conversation_command(update, "fork", argument)
        def regenerate(update, argument) = @runtime.conversation_command(update, "regenerate", argument)
        def variants(update, argument) = @runtime.conversation_command(update, "variants", argument)
        def variant(update, argument) = @runtime.conversation_command(update, "variant", argument)
        def edit(update, argument) = @runtime.conversation_command(update, "edit", argument)
        def undo(update, argument) = @runtime.conversation_command(update, "undo", argument)
        def context(update, argument) = @runtime.conversation_command(update, "context", argument)
        def compact(update, argument) = @runtime.conversation_command(update, "compact", argument)
        def task(update, argument) = @runtime.execution_command(update, argument)
        def transcript(update, argument) = @runtime.execution_transcript(update, argument)

        def queue(update, argument)
          action, value = argument.split(/\s+/, 2)
          case action
          when nil, "list"
            value ? queue_usage : @runtime.queue_list(update)
          when "edit", "reschedule", "cancel"
            number, text = value.to_s.split(/\s+/, 2)
            return queue_usage unless number && number.length <= 10 && number.match?(/\A[1-9][0-9]*\z/)
            return queue_usage if action != "cancel" && text.to_s.strip.empty?
            return queue_usage if action == "cancel" && text

            case action
            when "edit"
              @runtime.queue_edit(update, Integer(number, 10), text)
            when "reschedule"
              @runtime.queue_reschedule(update, Integer(number, 10), text)
            else
              @runtime.queue_cancel(update, Integer(number, 10))
            end
          else
            queue_usage
          end
        end

        def queue_usage
          "Use /queue, /queue edit NUMBER TEXT, /queue reschedule NUMBER in 20m|at TIME|now, or /queue cancel NUMBER. " \
            "Numbers refer to the most recent /queue list in this chat."
        end

        def remind(update, argument)
          mode, value, text = argument.split(/\s+/, 3)
          unless %w[in at].include?(mode) && value && !text.to_s.strip.empty?
            return "Use /remind in 20m TEXT or /remind at 2026-10-03T09:00:00+08:00 TEXT."
          end

          @runtime.remind(update, expression: "#{mode} #{value}", text: text)
          nil
        end

        def new(update, _argument)
          @runtime.open_route(update, fresh: true)
          "Started a new conversation. Earlier work still reports back here."
        end

        def stop(update, argument)
          return "Use /stop or /stop TASK_ID with the full ID from the task receipt." unless argument.empty? || TASK_ID.match?(argument)

          room = @runtime.room(update)
          if !argument.empty? || room["current"]
            @runtime.control do
              if argument.empty?
                @runtime.stop_conversation(update)
              else
                @runtime.stop_conversation(update, task_id: argument.downcase)
              end
              "Stop requested for this task, including its background work."
            end
          else
            "No conversation is open."
          end
        end

        def steer(update, argument)
          return "Use /steer <text> to add instructions to the current work." if argument.strip.empty?

          first, text = argument.split(/\s+/, 2)
          if self.class.task_reference?(first)
            return "Use /steer TASK_ID <text> with the full ID from the task receipt." unless TASK_ID.match?(first) && !text.to_s.strip.empty?

            @runtime.submit(update, text: text, mode: "steer", task_id: first.downcase)
          else
            @runtime.submit(update, text: argument, mode: "steer")
          end
          nil
        end

        def btw(update, argument)
          return "Use /btw <question> to ask a side question without tools." if argument.strip.empty?

          @runtime.side_question(update, argument)
          nil
        end

        def approve(update, argument) = decide(update, "approve", argument)
        def deny(update, argument) = decide(update, "deny", argument)
        def answer(update, argument) = decide(update, "answer", argument)

        def settings(update, _argument)
          room = @runtime.room(update)
          selected = @runtime.current_workspace(update)
          behavior = if update.group?
            "Group behavior:\nRequests: explicit mentions or replies to the bot or a known task.\n" \
              "#{observe_status(update)}\n#{mode_status(update)}\n\n" \
              "Your conversation settings in #{group_scope(update)}:\n"
          else
            "Your conversation settings in this private chat:\n"
          end
          behavior + "Workspace: #{workspace_label(selected)}\nModel: #{room["model"] || "rho default"}\nVoice: #{room.fetch("voice", "off")}\n" \
            "New message age limit: #{@runtime.settings.stale_after} seconds\n" +
            (update.group? ? "Group memory: shared in this chat/topic; task notes stay with this conversation. Owner personal memory and cross-conversation tools: excluded." : "Personal conversation")
        end

        def status(update, argument)
          return @runtime.work_status(update) if argument.empty?
          return "Use /status or /status TASK_ID with the full ID from the task receipt." unless TASK_ID.match?(argument)

          @runtime.task_status(update, argument.downcase)
        end

        def model(update, argument)
          models = @runtime.bridge.models
          return "Available models:\n#{models.join("\n")}\nUse /model provider/model." if argument.empty?
          return "That model is not available. Use /model to list the available models." unless models.include?(argument)

          @runtime.edit_room(update) { |room| room["model"] = argument }
          "Model set to #{argument} for new requests."
        end

        def workspace(update, argument)
          command, value = argument.split(/\s+/, 2)
          selected_id = @runtime.state.read.fetch("pending_update")["workspace_public_id"]
          if %w[use create].include?(command) && selected_id
            return switch_workspace(update, @runtime.bridge.workspace(selected_id))
          end

          case command
          when nil, "list", "current"
            workspace_overview(update, include_available: command != "current")
          when "use"
            return "Use /workspace use ID or an exact workspace name." if value.to_s.empty?

            rows = @runtime.bridge.workspaces
            selected = rows.find { |row| row.fetch("public_id") == value }
            unless selected
              matches = rows.select { |row| row.fetch("name") == value }
              return "Several workspaces have that name. Use the public ID from /workspace list." if matches.length > 1

              selected = matches.first
            end
            return "That workspace is not available. Use /workspace list." unless selected

            selected = @runtime.bridge.workspace(selected.fetch("public_id"))
            switch_workspace(update, selected)
          when "create"
            return "Use /workspace create NAME." if value.to_s.empty?

            selected = @runtime.bridge.create_workspace(name: value,
              idempotency_key: @runtime.update_key(update, "workspace"))
            switch_workspace(update, selected)
          else
            "Use /workspace list, /workspace current, /workspace use ID or /workspace create NAME."
          end
        end

        def workspace_overview(update, include_available:)
          listing = @runtime.bridge.workspace_state
          rows = listing.fetch("workspaces")
          route = @runtime.room(update)
          selected_id = workspace_identity(route, listing)
          selected = rows.find { |row| row.fetch("public_id") == selected_id }
          label = selected ? workspace_label(selected) : (selected_id ? "Unavailable (#{selected_id})" : (route["current"] ? "Unavailable" : "Not selected"))
          text = "Current workspace: #{label}"
          text += "\nAvailable workspaces:\n#{rows.map { |row| workspace_label(row) }.join("\n")}" if include_available
          text += "\nUse /workspace use ID or /workspace create NAME." if include_available || !selected
          text
        end

        def workspace_identity(route, listing)
          if route["workspace_public_id"]
            route.fetch("workspace_public_id")
          elsif route["current"]
            @runtime.bridge.conversation_workspace_id(route.fetch("current"))
          else
            listing["selection"] || listing.dig("workspace", "public_id")
          end
        rescue Rho::Core::Refused => error
          raise unless error.status == 404

          nil
        end

        def switch_workspace(update, selected)
          @runtime.open_route(update, fresh: true, workspace_public_id: selected.fetch("public_id"))
          "Workspace set to #{workspace_label(selected)}. Started a new conversation. Earlier work still reports back here."
        end

        def workspace_label(row)
          "#{row.fetch("name")} (#{row.fetch("public_id")})"
        end

        def observe(update, argument)
          return "Observe is only available in groups." unless update.group?
          case argument
          when "", "status"
            observe_status(update)
          when "on", "off"
            if (refusal = management_refusal(update))
              return refusal
            end
            if argument == "on" && !@runtime.can_observe?(update)
              return "Telegram is hiding background messages. Make this bot a group administrator or disable " \
                "Group Privacy in BotFather, then remove and re-add the bot and try again."
            end
            consequence = if argument == "on"
              "Allowed members' background messages are recorded without starting the agent."
            else
              "New background messages are not recorded or added to future requests. Previously recorded context and accepted tasks are kept."
            end
            @runtime.set_observe(update, argument == "on",
              result: "Observe is #{argument}. #{consequence}\nShared scope: #{group_scope(update)}.")
          else
            "Use /observe on, /observe off or /observe status."
          end
        end

        def observe_status(update)
          "Observe: #{@runtime.observed?(update) ? "on" : "off"}.\nShared scope: #{group_scope(update)}.\n" \
            "Only the bot owner can change this setting."
        end

        def mode(update, argument)
          return "Mode is only available in groups." unless update.group?

          case argument
          when "", "status"
            mode_status(update)
          when "assistant", "active"
            if (refusal = management_refusal(update))
              return refusal
            end

            @runtime.set_participation(update, argument,
              result: mode_status(update, selected: argument) + "\nOnly future messages are considered. Shared scope: #{group_scope(update)}.")
          else
            "Use /mode assistant, /mode active or /mode status."
          end
        end

        def mode_status(update, selected: @runtime.participation_mode(update))
          behavior = if selected == "assistant"
            "Background context does not start the agent."
          elsif @runtime.observed?(update)
            "rho may add a short reply when useful, using limited observed context."
          else
            "Active participation is paused because observe is off."
          end
          "Mode: #{selected}. #{behavior}\nOnly the bot owner can change this setting."
        end

        def group_scope(update)
          update.topic_id ? "this topic (#{update.topic_id}) in group #{update.chat_id}" : "this group (#{update.chat_id})"
        end

        def voice(update, argument)
          return "Voice replies: #{@runtime.room(update).fetch("voice", "off")}. Text replies are always kept." if argument.empty?
          unless %w[off voice_only all].include?(argument)
            return "Use /voice off, /voice voice_only or /voice all."
          end
          if argument != "off" && @runtime.settings.speech_model.empty?
            return "Spoken replies need telegram.speech_model configured in rho settings."
          end

          @runtime.edit_room(update) { |room| room["voice"] = argument }
          "Voice replies: #{argument}. Text replies are always kept."
        end

        def decide(update, name, argument)
          id, answer = argument.split(/\s+/, 2)
          question = @runtime.state.read.fetch("questions")[id]
          unless question && !question["resolved"]
            return "That request is no longer available in this chat."
          end
          refusal = @runtime.question_refusal(update, question, approval: name != "answer")
          return refusal if refusal
          if name == "answer"
            return "Use /answer ID your answer." if answer.to_s.empty?
            return "This request needs /approve or /deny, or attention in the rho CLI." unless question.fetch("kind") == "ask"

            result = @runtime.control do
              @runtime.bridge.answer(question.fetch("loop_public_id"), question.fetch("task_key"), answer,
                workspace_public_id: question.fetch("workspace_public_id"))
              "Response accepted."
            end
          else
            return "This is a question. Use /answer ID your answer." unless question.fetch("kind") == "approval"

            result = @runtime.control do
              @runtime.bridge.public_send(name, question.fetch("loop_public_id"), question.fetch("task_key"),
                workspace_public_id: question.fetch("workspace_public_id"))
              "Response accepted."
            end
          end
          @runtime.state.change do |document|
            # The follower can retire this question while the decision awaits Nexus.
            current = document.fetch("questions")[id]
            current["resolved"] = true if current
          end
          result
        end
    end
  end
end
