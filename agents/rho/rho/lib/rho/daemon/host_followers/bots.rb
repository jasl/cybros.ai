module Rho
  class Daemon
    class HostFollowers
      # Bot identity owns the current pointer. The scoped Store persists the
      # pending switch before any lifecycle write, so an interrupted command
      # finishes before the next switch or input admission.
      module Bots
        BOT_CONVERSATIONS_NAMESPACE = "rho.bot_conversations".freeze
        BOT_OPERATION_RETENTION = 86_400
        BOT_COMMAND_FIELDS = {
          "current" => %w[agent_public_id operation_id],
          "new" => %w[agent_public_id operation_id home_workspace_public_id],
          "resume" => %w[agent_public_id operation_id conversation_public_id workspace_public_id],
          "fork" => %w[agent_public_id operation_id conversation_public_id workspace_public_id turn_public_id variant_public_id],
        }.freeze

        def register_bots(api)
          api.register_route("GET", "/bots/detail") { |request, ctx| bot_detail(request, ctx) }
          api.register_route("GET", "/bots/history") { |request, ctx| bot_history(request, ctx) }
          BOT_COMMAND_FIELDS.each_key do |action|
            api.register_route("POST", "/bots/#{action}") { |request, ctx| bot_command(request, ctx, action) }
          end
        end

        def bot_detail(request, ctx)
          fields = ControlServer.query(request)
          ctx.member_plane(request, require_workspace: false) do |client, workspace, *|
            bot = editable_bot(client, fields["agent_public_id"].to_s)
            next bot if bot in Refusal

            projection = named_listing(client, workspace).fetch(:bots).find { |row| row.fetch(:public_id) == bot.public_id }
            settings = bot_settings(client, bot.public_id).read
            current = bot_document(client, bot.public_id).read.to_h["current"]
            welcome = settings.welcome_message || "Hello, I'm #{bot.display_name || bot.name}. #{bot.description}"
            [200, { bot: projection, current: current, effective_welcome_message: welcome }]
          end
        end

        def bot_history(request, ctx)
          fields = ControlServer.query(request)
          limit = Integer(fields["limit"], exception: false) if fields.key?("limit")
          return Refusal.malformed("limit must be a positive integer") if fields.key?("limit") && !limit&.positive?
          if fields.key?("archived") && !%w[0 1 true false].include?(fields["archived"])
            return Refusal.malformed("archived must be true or false")
          end

          ctx.member_plane(request, require_workspace: false) do |client, *|
            bot = editable_bot(client, fields["agent_public_id"].to_s)
            next bot if bot in Refusal

            archived = %w[1 true].include?(fields["archived"]) if fields.key?("archived")
            page = client.conversations.list(answering_user_public_id: bot.public_id,
              metadata_key: BotSettings::CONVERSATION_METADATA_KEY, metadata_value: bot.public_id,
              after: fields["after"], limit: limit, archived: archived, order_by: "last_activity_at", order: "desc")
            [200, { conversations: page.items.map { |row| Extensions::Ops::Conversations.summary(row, ctx).merge(bot_public_id: bot.public_id) },
                    pagination: { next_after: page.next_after } }]
          end
        end

        def bot_command(request, ctx, action)
          ctx.member_plane(request, body: true, require_workspace: false) do |client, _workspace, _about, fields|
            unknown = fields.keys - BOT_COMMAND_FIELDS.fetch(action)
            next Refusal.malformed("unknown fields: #{unknown.join(", ")}") unless unknown.empty?
            operation = fields["operation_id"].to_s
            next Refusal.malformed("operation_id is required and must fit 128 bytes") if operation.empty? || operation.bytesize > 128

            bot = editable_bot(client, fields["agent_public_id"].to_s)
            next bot if bot in Refusal

            answer = with_bot_gate(bot.public_id) { switch_bot(client, bot, action, fields) }
            (answer in Refusal) ? answer : [200, answer]
          end
        end

        # Settings writes share the switch gate. A later Home edit must not be
        # overwritten by recovery of an earlier /workspace switch.
        def bot_settings_gate(client, agent_public_id)
          with_bot_gate(agent_public_id) do
            recovered = recover_bot_switch(client, agent_public_id)
            (recovered in Refusal) ? recovered : yield
          end
        end

        private

          def bot_open_refusal(client, answerer)
            return if answerer.nil? || answerer.public_id == @context.own_user_public_id

            bot = client.profile.agents.list.find do |candidate|
              candidate.public_id == answerer.public_id && candidate.derived_from_public_id == @context.own_user_public_id &&
                !registered_names.include?(candidate.name)
            end
            return unless bot

            Refusal.new(status: 409, code: "bot_conversation_required",
              message: "Open this Bot through its current conversation, or create a new Bot conversation")
          end

          def editable_bot(client, public_id)
            return Refusal.malformed("agent_public_id is required") if public_id.empty?

            row = client.profile.agents.list.find do |candidate|
              candidate.public_id == public_id && candidate.derived_from_public_id == @context.own_user_public_id &&
                !registered_names.include?(candidate.name)
            end
            row || Refusal.new(status: 404, code: "not_found", message: "No editable Bot with public id #{public_id}")
          end

          def with_bot_gate(public_id)
            @bot_gates ||= {}
            (@bot_gates[public_id] ||= Async::Semaphore.new(1)).acquire { yield }
          end

          def bot_document(client, public_id)
            @bot_documents ||= {}
            @bot_store_clients ||= {}
            key = [@context.own_user_public_id, public_id]
            @bot_store_clients[key] = client
            @bot_documents[key] ||= StoreDocument.new(store: -> { @bot_store_clients.fetch(key).profile.store_entries },
              namespace: BOT_CONVERSATIONS_NAMESPACE, key: public_id)
          end

          def switch_bot(client, bot, action, fields)
            document = bot_document(client, bot.public_id)
            request = fields.except("operation_id")
            operation = fields.fetch("operation_id")
            state = document.read.to_h
            prior = state.fetch("receipts", {})[operation] || (state["pending"] if state.dig("pending", "operation_id") == operation)
            if prior && (prior.fetch("action") != action || prior.fetch("request") != request)
              return Refusal.new(status: 409, code: "idempotency_envelope_mismatch", message: "This operation_id belongs to a different Bot command")
            end
            recovered = recover_bot_switch(client, bot.public_id)
            return recovered if recovered in Refusal

            state = document.read.to_h
            if (receipt = state.fetch("receipts", {})[operation])
              return { current: state["current"], selected: receipt.fetch("selected"), replayed: true }
            end

            pending = prepare_bot_switch(client, bot, action, fields, state["current"])
            return pending if pending in Refusal

            document.change do |value|
              value["receipts"] = value.fetch("receipts", {}).reject { |_, row| row.fetch("completed_at") < @clock.call.to_i - BOT_OPERATION_RETENTION }
              value["pending"] = pending
            end
            result = recover_bot_switch(client, bot.public_id)
            return result if result in Refusal

            state = document.read.to_h
            { current: state.fetch("current"), selected: state.fetch("receipts").fetch(operation).fetch("selected"), replayed: false }
          end

          def prepare_bot_switch(client, bot, action, fields, current)
            pending = { "operation_id" => fields.fetch("operation_id"), "action" => action,
              "request" => fields.except("operation_id"), "previous" => current }
            if action == "current" && current
              selected = bot_conversation(client, current).fetch
              unless selected.archived?
                return pending.merge("selected" => current)
              end
            end
            if %w[resume fork].include?(action)
              locator = fields.slice("conversation_public_id", "workspace_public_id")
                .transform_keys { |key| key == "conversation_public_id" ? "public_id" : key }
              if locator.values.any? { |value| value.to_s.empty? } || locator.length != 2
                return Refusal.malformed("conversation_public_id and workspace_public_id are required")
              end
              source = bot_conversation(client, locator).fetch
              unless source.metadata[BotSettings::CONVERSATION_METADATA_KEY] == bot.public_id && source.answering_user_public_id == bot.public_id && !source.subagent? && !source.side?
                return Refusal.new(status: 409, code: "bot_conversation_mismatch", message: "Choose a root conversation from this Bot's history")
              end
              if action == "resume"
                return pending.merge("selected" => locator)
              end
              return Refusal.malformed("turn_public_id is required") if fields["turn_public_id"].to_s.empty?

              return pending.merge("source" => locator, "fork" => fields.slice("turn_public_id", "variant_public_id"))
            end

            settings = bot_settings(client, bot.public_id).read
            workspace_id = fields.fetch("home_workspace_public_id", settings.home_workspace_public_id)
            if workspace_id.to_s.empty?
              return Refusal.new(status: 409, code: "bot_home_required", message: "Choose this Bot's Home Workspace before opening its conversation")
            end
            workspace = Workspaces.fetch(client, workspace_id)
            return workspace if workspace in Refusal

            runner = settings.audience == "external" ? nil : @context.runner_selection({})
            pending.merge("workspace_public_id" => workspace_id,
              "create" => { "answering_user_public_id" => bot.public_id, "metadata" => { BotSettings::CONVERSATION_METADATA_KEY => bot.public_id },
                "default_runner_executor_public_id" => runner, "memory_context" => Speakers.memory_context(audience: settings.audience) })
          end

          def recover_bot_switch(client, public_id)
            document = bot_document(client, public_id)
            pending = document.read.to_h["pending"]
            return unless pending

            selected = pending["selected"]
            unless selected
              created = if pending["source"]
                bot_conversation(client, pending.fetch("source")).fork(idempotency_key: pending.fetch("operation_id"),
                  **pending.fetch("fork").transform_keys(&:to_sym)).conversation
              else
                client.workspace(pending.fetch("workspace_public_id")).conversations.create(idempotency_key: pending.fetch("operation_id"),
                  **pending.fetch("create").transform_keys(&:to_sym)).conversation
              end
              unless pending["source"]
                host = Host::Conversation.new(public_id: created.public_id)
                hosted = host.context(client.workspace(created.workspace_public_id))
                create_policy(host, hosted, code_mode: false, subagent: true, title_pending: created.title.to_s.empty?) if read_policy(host, hosted).nil?
              end
              selected = { "public_id" => created.public_id, "workspace_public_id" => created.workspace_public_id }
              document.change { |value| value.fetch("pending")["selected"] = selected }
            end

            hosted = bot_conversation(client, selected)
            conversation = hosted.fetch
            conversation = hosted.unarchive if conversation.archived?
            unless conversation.metadata[BotSettings::CONVERSATION_METADATA_KEY] == public_id
              conversation = hosted.update(metadata: conversation.metadata.merge(BotSettings::CONVERSATION_METADATA_KEY => public_id), lock_version: conversation.lock_version)
            end
            if pending.fetch("request").key?("home_workspace_public_id")
              bot_settings(client, public_id).replace(home_workspace_public_id: pending.fetch("request").fetch("home_workspace_public_id"))
            end
            previous = pending["previous"]
            if previous && previous != selected
              previous_workspace = client.workspaces.fetch(previous.fetch("workspace_public_id"))
              # An archived Workspace already forbids new work and cannot accept
              # this write. If restored, the Bot's current selection still gates input.
              if previous_workspace.state != "archived"
                bot_conversation(client, previous).archive
              end
            end
            adopt_bot_conversation(client, conversation)
            document.change do |value|
              value["current"] = selected
              value["receipts"] ||= {}
              value["receipts"][pending.fetch("operation_id")] = pending.slice("action", "request").merge(
                "selected" => selected, "completed_at" => @clock.call.to_i)
              value.delete("pending")
            end
            nil
          end

          def bot_conversation(client, locator)
            client.workspace(locator.fetch("workspace_public_id")).conversation(locator.fetch("public_id"))
          end

          def adopt_bot_conversation(client, conversation)
            workspace = client.workspace(conversation.workspace_public_id)
            host = Host::Conversation.new(public_id: conversation.public_id)
            hosted = host.context(workspace)
            restore_policy(host, hosted, document: conversation)
            create_policy(host, hosted, code_mode: false, subagent: true) if read_policy(host, hosted).nil?
            adopt_follower(host, hosted, {}, runs: workspace.runs)
          end

          # The gate covers only accepted-input creation. Uploading, transcribing,
          # debounce and model completion all happen outside it. An old archived
          # host still reaches Nexus so an accepted input replay or exact live-run
          # steer can use the kernel's existing authority.
          def admit_bot_input(client, document, hosted)
            public_id = document&.metadata&.[](BotSettings::CONVERSATION_METADATA_KEY)
            return yield(true) unless public_id

            with_bot_gate(public_id) do
              recovered = recover_bot_switch(client, public_id)
              next recovered if recovered in Refusal

              current = bot_document(client, public_id).read.to_h["current"]
              selected = current && current["public_id"] == document.public_id && current["workspace_public_id"] == document.workspace_public_id
              archived = hosted.fetch.archived?
              unless selected
                unless archived
                  next Refusal.new(status: 409, code: "bot_resume_required", message: "Resume this Bot conversation before starting another task")
                end
              end
              yield(selected && !archived)
            end
          end
      end
    end
  end
end
