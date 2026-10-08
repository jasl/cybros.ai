require "async"
require "digest"
require_relative "input_workflow"
require_relative "speech_workflow"
require_relative "session_workflow"
require_relative "conversation_workflow"
require_relative "candidate_workflow"
require_relative "queue_workflow"
require_relative "task_routing"
require_relative "participation_workflow"
require_relative "access"
require_relative "memory_workflow"
require_relative "reminder_workflow"
require_relative "destination_workflow"
require_relative "schedule_workflow"
require_relative "worker_tracking"

module Rho
  module IngressTelegram
    # One long poll consumes updates serially; a separate task follows every bound
    # conversation and drains formal messages. Neither waits for a model to finish.
    class Runtime
      include InputWorkflow
      include SpeechWorkflow
      include SessionWorkflow
      include ConversationWorkflow
      include CandidateWorkflow
      include QueueWorkflow
      include TaskRouting
      include ParticipationWorkflow
      include MemoryWorkflow
      include ReminderWorkflow
      include DestinationWorkflow
      include ScheduleWorkflow
      include WorkerTracking
      RECONCILE_INTERVAL = 5
      HISTORY_REFRESH_INTERVAL = 60

      # A disposable read hint, never an event cursor or delivery receipt. The
      # daemon's existing follower owns replay; restart reads durable history again.
      HistoryRead = Data.define(:run, :voice_inputs, :at)

      attr_reader :settings, :state, :bridge

      def initialize(settings:, state:, bridge:, client:, log:, default_model: nil, clock: -> { Time.now.to_f })
        @settings, @state, @bridge, @client, @log = settings, state, bridge, client, log
        @clock, @default_model = clock, default_model
        @access = Access.new(settings: settings, state: state)
        @commands = Commands.new(self)
        @delivery = Delivery.new(client: client, state: state, bridge: bridge, limits: RateLimit.new(clock: clock), clock: clock)
        @closed = false
        @next_reconcile_at = 0
        @history_reads = {}
        @turn_pages = {}
        @connection = "starting"
      end

      def start
        until @bot || @closed
          safely("identify") { identify(@client.call("getMe")) }
        end
        return if @closed

        @connection = "running"
        safely("commands") { @client.call("setMyCommands", { commands: Commands::MENU }) }
        parent = Async::Task.current
        follower = parent.async do
          until @closed
            safely("follow") { tick }
            sleep 1
          end
        end
        until @closed
          safely("poll") do
            poll
            @connection = "running" unless @closed
          end
        end
      ensure
        follower&.stop
        @client.close
      end

      def close
        @closed = true
        @connection = "stopped"
        @client.close
      end

      def configure(settings:, default_model:)
        @settings, @default_model = settings, default_model
        @access = Access.new(settings: settings, state: @state)
      end

      def bot = @bot&.slice("id", "username")

      # Also used by deterministic adapter tests; no network request is hidden here.
      def identify(bot)
        @state.bind(bot.fetch("id"))
        @bot = bot
      end

      def consume(raw)
        held = @state.read
        return if held["offset"] && raw.fetch("update_id") < held.fetch("offset")

        update = Update.new(raw)
        # Age gates first admission. A staged update may already have spent its
        # idempotency key and must recover the original acceptance instead.
        if !held["pending_update"] && update.supported? && update.stale?(@clock.call, @settings.stale_after)
          @state.consumed(update.id)
          return
        end
        selection = update.supported? ? routing_selection(update, held) : {}
        key = selection["route_key"]
        current = selection["conversation_id"] || held.fetch("routes").dig(key, "current")
        pending = @state.stage("update" => raw, "conversation_id" => current,
          "model" => held.fetch("routes").dig(key, "model") || @default_model, **selection)
        update = Update.new(pending.fetch("update"), pending["route_key"])
        process(update, recovering: !!held["pending_update"])
        @state.consumed(update.id)
        # Zero still saves the receipt before submission, but need not wait for
        # the next timer pass. Media keeps its existing preparation cadence.
        reconcile_inputs(media: false) if @settings.input_debounce_seconds.zero?
      end

      def tick
        snapshots, refreshed, reads = {}, {}, {}
        runs = @bridge.runs
        reconcile = @clock.call >= @next_reconcile_at
        @next_reconcile_at = @clock.call + RECONCILE_INTERVAL if reconcile
        reconcile_inputs(media: reconcile)
        @state.read.fetch("routes").each do |key, route|
          next unless permitted_route?(route)

          route.fetch("conversations").each do |conversation_id, cursor|
            safely("conversation") do
              run = runs[conversation_id]
              hint = history_read_due(conversation_id, run, cursor)
              settled = run && %w[completed failed canceled].include?(run["status"])
              # A completed reply uses the next local event hint. Running work
              # and attention discovery retain the bounded reconciliation cadence.
              unless reconcile || (settled && hint)
                snapshots[conversation_id] = @bridge.progress(run) if run
                next
              end

              snapshot = run && @bridge.progress(run)
              if hint
                snapshot = refresh_history(key, route, conversation_id, cursor, run, hint)
                next unless snapshot
              end

              # A child can ask while its parent's event sequence stays still.
              # Keep the existing per-workspace attention read independent of history.
              if reconcile
                collect_questions(key, route, conversation_id, cursor.fetch("workspace_public_id"), reads: reads)
                refreshed[conversation_id] = true
              end
              snapshots[conversation_id] = snapshot if snapshot
            end
          end
        end
        reconcile_speech if reconcile
        reconcile_participation(runs) if reconcile
        # Formal answers and controls get the first opportunity at the chat budget.
        @delivery.flush do |entry|
          question = @state.read.fetch("questions")[entry["question_id"]]
          question_current = !entry["question_id"] ||
            (question && !question["resolved"] && refreshed.key?(question.fetch("conversation_id")))
          (permitted_route?(entry) || entry["guidance"]) && question_current && current_delivery?(entry)
        end
        @state.read.fetch("routes").each_value do |route|
          id = route["current"]
          next unless id
          next unless route.fetch("conversations").key?(id)
          next unless permitted_route?(route)

          snapshot = snapshots[id]
          safely("progress") { @delivery.progress(route, id, snapshot) } if snapshot
        end
        prune_receipts
      end

      def room(update)
        persisted = @state.read
        row = persisted.fetch("routes").fetch(update.route_key, new_route(update))
        pending = persisted["pending_update"]
        if pending && pending.fetch("update").fetch("update_id") == update.id && pending["conversation_id"]
          row.merge("current" => pending.fetch("conversation_id"))
        else
          row
        end
      end

      def edit_room(update)
        @state.change do |document|
          row = document.fetch("routes")[update.route_key] ||= new_route(update)
          yield(row)
        end
      end

      def open_route(update, fresh: false, workspace_public_id: nil)
        discard_pending_inputs(update.route_key) if fresh
        route = room(update)
        current = route["current"]
        if current && !fresh
          unless route.fetch("conversations").key?(current)
            raise Rho::Error, "This conversation is no longer followed. Use /new or /workspace list to continue."
          end
          ensure_memory_binding(update, route, current, workspace_for(route, current))
          return current
        end

        pending = @state.read.fetch("pending_update")
        workspace_id = pending["workspace_public_id"] || workspace_public_id ||
          route["workspace_public_id"] || current_workspace(update).fetch("public_id")
        # Freeze the scope before IO: a lost create reply must not be replayed in
        # another workspace after the daemon's default changes.
        @state.change { |document| document.fetch("pending_update")["workspace_public_id"] = workspace_id }
        context = memory_context(update, route, workspace_id)
        id = @bridge.open(idempotency_key: update_key(update, "conversation"), group: update.group?,
          isolated: !@access.owner?(route.fetch("owner_id")),
          workspace_public_id: workspace_id, memory_context: context)
        @state.change do |document|
          row = document.fetch("routes")[update.route_key] ||= new_route(update)
          row.merge!("current" => id, "workspace_public_id" => workspace_id)
          row.fetch("conversations")[id] ||= { "position" => nil, "workspace_public_id" => workspace_id, "memory_bound" => true }
          document.fetch("pending_update")["conversation_id"] = id
        end
        id
      end

      def workspace_for(route, conversation_id)
        tracker = route.fetch("conversations")[conversation_id]
        unless tracker
          raise Rho::Error, "This conversation is no longer followed. Use /new or /workspace list to continue."
        end

        tracker.fetch("workspace_public_id")
      end

      def current_workspace(update)
        route = room(update)
        if route["workspace_public_id"]
          @bridge.workspace(route.fetch("workspace_public_id"))
        elsif route["current"]
          @bridge.conversation_workspace(route.fetch("current"))
        else
          @bridge.default_workspace
        end
      end

      def update_key(update, purpose)
        "telegram:#{@bot.fetch("id")}:#{update.id}:#{purpose}"
      end

      def reply(update, text, guidance: false, request_id: nil)
        request_id ||= @state.read.fetch("pending_update", {}).to_h["candidate_request_id"]
        @state.enqueue("control:#{update.id}", route: update.route.merge("route_key" => update.route_key), text: text,
          plain: true, guidance: guidance, request_id: request_id)
      end

      def submit(update, text:, mode: "queue", observe: false, task_id: nil, deliver_at: nil)
        return observe_message(update, text) if observe

        if mode == "steer" && (update.media || update.unsupported_media?)
          raise Rho::Error, "/steer accepts text only. Send attachments as a normal queued message."
        end
        target = task_target(update, task_id: task_id) if mode == "steer"
        if target && !target["run_id"]
          raise Rho::Error, "This task has no known execution to steer. Check /status TASK_ID; waiting inputs can be changed through /queue."
        end
        if target && (refusal = execution_control_refusal(update, target.fetch("run_id"), target.fetch("workspace_public_id")))
          raise Rho::Error, refusal
        end
        source_id = target ? target.fetch("conversation_id") : open_route(update)
        conversation_id = target ? target.fetch("execution_conversation_id", source_id) : source_id
        key = prepare_request(update, conversation_id) unless target
        context = observation_context(update) unless target
        source_key = target ? target.fetch("route_key") : update.route_key
        source_route = target ? @state.read.fetch("routes").fetch(source_key) : room(update)
        workspace_id = workspace_for(source_route, source_id)
        fields = { tool_names: input_tool_names(user_id: update.user_id, group: source_route.fetch("group"),
          route_key: source_key, conversation_id: source_id) }.compact
        fields[:isolated] = true unless @access.owner?(update.user_id)
        fields[:deliver_at] = deliver_at if deliver_at
        fields[:expected_steering_run_public_id] = target.fetch("run_id") if target
        fields[:inline] = [{ "role" => "user", "position" => "lead", "text" => context }] if context
        answer = @bridge.submit(conversation_id, text: text, speaker: speaker_for(update),
          idempotency_key: update_key(update, "input"), mode: mode, observe: observe,
          model: @state.read.fetch("pending_update")["model"],
          workspace_public_id: workspace_id, **fields)
        pending = @state.read.fetch("pending_update")
        accepted_request(key || pending["request_id"] || pending.fetch("report_id"), answer,
          primary: !target, report: !!target&.fetch("parent_report", false))

        receipt = if deliver_at
          "Reminder scheduled for #{answer.fetch("input").fetch("deliver_at")}. It may arrive later while this conversation is busy.\n" \
            "Use /queue to reschedule or cancel it.\nTask: #{answer.fetch("input").fetch("public_id")}"
        elsif mode == "steer"
          "Your additional instruction is accepted for the next model step. Running tools are not interrupted."
        else
          # Ordinary chat answers through its assistant reply. Queue admission
          # is an internal fact, not a promise that background work has started.
          nil
        end
        reply(update, receipt, request_id: key || @state.read.fetch("pending_update")["request_id"]) if receipt
      end

      def stop_conversation(update, task_id: nil)
        target = task_target(update, task_id: task_id, allow_pending_inputs: true)
        unless target["run_id"]
          if target["parent_report"] || (target["execution_conversation_id"] && !target["schedule_id"])
            raise Rho::Error, "This task's original execution is not linked. Check /status TASK_ID."
          end
          if task_id
            raise Rho::Error, "This task's input is already canceled." if target["retired"]

            # Delete addresses the accepted input itself. If it materializes
            # concurrently, Nexus refuses; never redirect Stop to a current loop.
            return @bridge.delete_input(target.fetch("execution_conversation_id", target.fetch("conversation_id")), task_id, workspace_public_id: target.fetch("workspace_public_id"))
          end
          return discard_pending_inputs(target.fetch("route_key"), request_id: @state.read.fetch("pending_update").fetch("request_id"))
        end

        cancel_task_speech(target)
        @bridge.stop(target.fetch("run_id"), host_type: "run", workspace_public_id: target.fetch("workspace_public_id"))
      end

      def question_reply_id(update)
        message = update.message["reply_to_message"]
        if message && message.dig("from", "id").to_s == @bot.fetch("id").to_s
          message.fetch("text", "").match(/\AQuestion \(([0-9a-f]{12})\)\n/)&.captures&.first
        end
      end

      # These commands have effects, but no server idempotency receipt. A lost reply
      # is uncertainty, not permission to apply Stop to a later execution.
      def control
        @state.change { |document| document.fetch("pending_update")["control_status"] = "applying" }
        result = yield
        @state.change do |document|
          document.fetch("pending_update").merge!("control_status" => "applied", "control_result" => result)
        end
        result
      end

      def can_observe?(update)
        # BotFather can change privacy while this daemon stays online.
        return true if @client.call("getMe")["can_read_all_group_messages"]

        member = @client.call("getChatMember", { chat_id: update.chat_id, user_id: @bot.fetch("id") })
        %w[administrator creator].include?(member.fetch("status"))
      end

      def status
        @state.status.merge("enabled" => @settings.enabled?, "connection" => @connection)
      rescue Rho::ConnectionError, CybrosAgent::TransportError, CybrosAgent::Api::Error
        { "enabled" => @settings.enabled?, "connection" => "waiting_for_nexus" }
      end

      private

        # The Telegram identity owns this policy in private chats as well as
        # groups. Intersect the current answerer's actual spellings so unavailable
        # tools are never requested.
        def input_tool_names(user_id:, group:, route_key:, conversation_id:)
          return if @access.owner?(user_id)

          tracker = @state.read.fetch("routes").fetch(route_key).fetch("conversations").fetch(conversation_id)
          @bridge.read_only_tool_names(conversation_id, group: true,
            workspace_public_id: tracker.fetch("workspace_public_id"))
        end

        def new_route(update)
          update.route.merge("route_key" => update.route_key, "owner_id" => update.user_id, "conversations" => {})
        end

        def poll
          if (pending = @state.read["pending_update"])
            consume(pending.fetch("update"))
            return
          end
          options = { timeout: 30, limit: 50, allowed_updates: %w[message callback_query stopped_message_generation] }
          options[:offset] = @state.read["offset"] if @state.read["offset"]
          @client.call("getUpdates", options, poll: true).each { |update| consume(update) }
        end

        def process(update, recovering:)
          observing = false
          return unless update.supported?
          if update.group? && !@access.allowed_chat?(update.chat_id)
            retire_unaccepted_request(update) if recovering
            return
          end

          command = update.command(@bot.fetch("username"))
          return if command&.first == "addressed_elsewhere"
          if @access.ignored?(update.user_id)
            retire_unaccepted_request(update) if recovering
            return
          end
          unless @access.allowed?(update.user_id)
            retire_unaccepted_request(update) if recovering
            if !update.group? && command&.first == "start"
              reply(update, "This bot is private. Ask its operator to allow your Telegram user ID: #{update.user_id}.", guidance: true)
            end
            return
          end
          note_participation_activity(update)
          if !local_settings_command?(update, command) && !explicit_task_command?(command) && (refusal = reply_target_refusal(update))
            return reply(update, refusal)
          end
          pending = @state.read.fetch("pending_update")
          if pending["control_status"]
            return reply(update, pending["control_result"] ||
              "The previous control may have succeeded. It was not repeated. Use /status to check the current state.")
          end
          # Telegram dates have whole-second precision. Stay inside Nexus's
          # 24-hour receipt window without inventing a later acceptance time.
          if recovering && update.stale?(@clock.call, 24 * 60 * 60 - 1)
            retire_unaccepted_request(update)
            return reply(update, "The previous request may already have been accepted. It was not resubmitted because its recovery window expired. " \
              "Use /queue, /history or /job list to check before sending it again.")
          end
          return stop_draft(update) if update.stopped
          return callback(update) if update.callback
          return @commands.call(update, *command) if command
          return if @commands.answer_reply(update)
          return if update.text.empty? && !update.media && !update.unsupported_media?

          triggered = update.triggers?(@bot) || !!pending["request_id"] || burst_waiting?(update)
          return unless triggered || observed?(update)

          if update.unsupported_media?
            return reply(update, "Please send a photo, a document or a voice message. Music messages, video, stickers and animations are not supported here yet.") if triggered
            return
          end
          if update.media&.fetch("kind") == "voice" && triggered && @settings.transcription_model.empty?
            return reply(update, "Voice messages need telegram.transcription_model configured in rho settings. You can type your message instead.")
          end

          unless triggered
            observing = true
            text = update.media ? [update.text, "[#{update.media.fetch("kind")} attachment]"].reject(&:empty?).join("\n") : update.text
            return submit(update, text: text, observe: true)
          end
          stage_input(update, open_route(update), speaker_for(update), triggered)
        rescue Rho::ConnectionError
          raise
        rescue Rho::Core::Refused => error
          raise if error.status >= 500 || error.status == 429
          return if observing

          retire_unaccepted_request(update)
          reply(update, "Request not accepted: #{Render.preview(error.message, limit: 600)}")
        rescue CybrosAgent::Api::InvalidRequest, CybrosAgent::Api::Conflict, CybrosAgent::Api::Forbidden => error
          return if observing

          retire_unaccepted_request(update)
          reply(update, "Request not accepted: #{error.code || "invalid request"}. Check rho telegram status locally.")
        rescue Rho::Error => error
          # Explicit application refusals are consumed. Transport failures remain pending
          # and retry the same Nexus idempotency key; neither can silently start a new turn.
          unless observing
            retire_unaccepted_request(update)
            reply(update, "Request not accepted: #{Render.preview(error.message, limit: 600)}")
          end
        end

        def speaker_for(update)
          existing = @state.read.fetch("speakers")[update.user_id]
          return existing if existing

          id = @bridge.register_speaker(bot_id: @bot.fetch("id"), user: update.user)
          @state.change { |document| document.fetch("speakers")[update.user_id] = id }
          id
        end

        def callback(update)
          name, argument = update.callback.fetch("data", "").split(":", 2)
          return unless %w[approve deny].include?(name)

          @commands.call(update, name, argument.to_s)
          @client.call("answerCallbackQuery", { callback_query_id: update.callback.fetch("id") })
        rescue Client::Refused => error
          @delivery.throttle(error.retry_after) if error.retry_after
        rescue Client::Unavailable
          # Acknowledging the spinner is not the decision; its separate durable reply
          # and the kernel's exact loop/task decision remain authoritative.
          nil
        end

        def stop_draft(update)
          route = room(update)
          owner = route["draft"]
          return unless owner && owner.fetch("id") == update.stopped.fetch("draft_id")
          return unless owner.fetch("conversation_id") == route["current"]

          workspace_id = workspace_for(route, owner.fetch("conversation_id"))
          current = @bridge.snapshot(owner.fetch("conversation_id"), workspace_public_id: workspace_id)
          return unless current["run_public_id"] == owner.fetch("run_id")
          return unless %w[running waiting queued pending paused needs_attention].include?(current.fetch("status"))

          text = control do
            @bridge.stop(owner.fetch("run_id"), host_type: "run", workspace_public_id: workspace_id)
            "Stop requested for this execution."
          end
          reply(update, text)
        end

        def history_read_due(conversation_id, run, cursor)
          # Expired event recovery can change the projection without advancing its
          # sequence. Voice admission also needs a read before the next local wake.
          hint = HistoryRead.new(run: run&.slice("sequence", "turn", "run_public_id", "status", "run_status", "complete", "blocked"),
            voice_inputs: cursor.fetch("voice_inputs", []), at: @clock.call)
          previous = @history_reads[conversation_id]
          if cursor.fetch("candidate_watches", {}).any? || previous.nil? || previous.run != hint.run || previous.voice_inputs != hint.voice_inputs ||
              hint.at - previous.at >= HISTORY_REFRESH_INTERVAL
            hint
          end
        end

        def refresh_history(route_key, route, conversation_id, cursor, run, hint)
          # Failure must leave this read eligible even when voice mapping changed
          # local state before a later read failed.
          @history_reads.delete(conversation_id)
          return unless reconcile_candidates(route_key, route, conversation_id, cursor)

          fresh_page = !@turn_pages.key?(conversation_id)
          if fresh_page
            page = read_source(conversation_id) do
              @bridge.turns(conversation_id, after_position: cursor.fetch("position"), workspace_public_id: cursor.fetch("workspace_public_id"))
            end
            return unless page

            @turn_pages[conversation_id] = page
          end
          # Capture this bounded REST page before freezing the event watermark.
          # A newer REST answer must not overtake its materialization identity.
          return unless read_source(conversation_id) do
            map_requests(route_key, conversation_id, cursor, fresh_page: fresh_page)
          end

          return unless read_source(conversation_id) { reconcile_schedules(route_key, conversation_id, cursor) }

          reconcile_worker_requests(conversation_id, cursor, run)
          map_durable_turn_sources(@turn_pages.fetch(conversation_id), conversation_id: conversation_id)
          map_voice_inputs(route_key, conversation_id, cursor)
          turns = collect_turns(route_key, route, conversation_id, cursor, @turn_pages.fetch(conversation_id))
          @turn_pages.delete(conversation_id)
          return unless turns

          snapshot = @bridge.snapshot(conversation_id,
            workspace_public_id: cursor.fetch("workspace_public_id"), run: run)
          if (blocked = snapshot["blocked_input_public_id"])
            @state.enqueue("blocked:#{conversation_id}:#{blocked}", route: route,
              text: "A queued request needs attention. Use the rho CLI to resolve it.", plain: true,
              conversation_id: conversation_id)
          end
          # Core bounds a history read. Any advancing page gets another pass;
          # an empty tail or an unfinished first turn needs a new wake or the floor.
          # A retained page predates this pass's hint and needs another fresh read.
          first = turns.first
          if fresh_page && (first.nil? || %w[pending running].include?(first.fetch("status")))
            @history_reads[conversation_id] = hint
          end
          snapshot
        end

        def collect_turns(route_key, route, conversation_id, cursor, turns)
          turns.each do |turn|
            break if %w[pending running].include?(turn.fetch("status"))

            if turn.fetch("kind") == "direct_reply" && !turn["inherited"]
              text = turn.fetch("text", "")
              media = turn.fetch("status") == "completed" ? @bridge.turn_media(turn, workspace_public_id: cursor.fetch("workspace_public_id")) : []
              if text.empty?
                text = case turn.fetch("status")
                when "canceled" then "Stopped."
                when "failed" then "The request needs attention. Use /status."
                else nil
                end
              end
              if text || !media.empty?
                request = request_for_turn(conversation_id, turn.fetch("public_id"), variant_id: turn["variant_public_id"])
                # Acceptance can still be awaiting its HTTP response while the
                # follower sees completion. Publish only after that identity is saved.
                break if !request && unacknowledged_request?(conversation_id)
                queue_result_delivery(route, conversation_id, turn, text.to_s, media, cursor.fetch("workspace_public_id"), request&.first)
                queue_speech(route_key, route, conversation_id, turn, text.to_s, cursor.fetch("workspace_public_id")) if turn.fetch("status") == "completed"
              end
            end
            @state.change do |document|
              tracker = document.fetch("routes").fetch(route_key).fetch("conversations").fetch(conversation_id)
              tracker["position"] = [tracker["position"], turn.fetch("position")].compact.max
              tracker.fetch("voice_turns", []).delete(turn.fetch("public_id"))
            end
          end
          turns
        end

        def read_source(conversation_id)
          yield
        rescue Rho::Core::Refused => error
          raise unless [403, 404].include?(error.status)

          retire_source(conversation_id)
          nil
        end

        def retire_source(conversation_id)
          @history_reads.delete(conversation_id)
          @turn_pages.delete(conversation_id)
          discard_source_inputs(conversation_id)
          @state.change do |document|
            question_ids = document.fetch("questions").filter_map do |id, question|
              id if question.fetch("conversation_id") == conversation_id
            end
            question_ids.each { |id| document.fetch("questions").delete(id) }
            document.fetch("deliveries").delete_if do |_key, entry|
              %w[pending preparing].include?(entry.fetch("status")) &&
                (entry["conversation_id"] == conversation_id || question_ids.include?(entry["question_id"]))
            end
            document.fetch("routes").each_value do |route|
              next unless route.fetch("conversations").delete(conversation_id)

              route.delete("draft") if route.dig("draft", "conversation_id") == conversation_id
              # Keep current: recovery is an explicit /new or workspace choice, not
              # an automatic new conversation after read access has disappeared.
              document.fetch("deliveries")["unavailable:#{conversation_id}"] ||= route.slice("chat_id", "topic_id", "group").merge(
                "status" => "pending", "plain" => true,
                "text" => "A followed conversation is no longer readable. Its pending replies and controls were removed. Use /new or /workspace list to continue."
              )
            end
          end
        end

        def current_delivery?(entry)
          return participation_delivery_current?(entry) if entry["participation_key"]
          return current_worker_delivery?(entry) if entry["canonical_result"]
          return true unless entry["turn_id"]

          current = false
          safely("delivery source") do
            route = @state.read.fetch("routes").values.find { |row| row.fetch("conversations").key?(entry.fetch("conversation_id")) }
            next unless route
            workspace_id = workspace_for(route, entry.fetch("conversation_id"))
            turn = read_source(entry.fetch("conversation_id")) do
              @bridge.turn_source(entry.fetch("conversation_id"), position: entry.fetch("position"), workspace_public_id: workspace_id)
            end
            current = turn && turn.fetch("public_id") == entry.fetch("turn_id") &&
              turn.fetch("variant_public_id") == entry.fetch("variant_public_id") &&
              !%w[pending running].include?(turn.fetch("status"))
            unless current
              removed = []
              @state.change do |document|
                document.fetch("deliveries").delete_if do |_key, row|
                  matches = row["conversation_id"] == entry.fetch("conversation_id") && row["turn_id"] == entry.fetch("turn_id") &&
                    row["variant_public_id"] == entry.fetch("variant_public_id") &&
                    %w[pending preparing].include?(row.fetch("status"))
                  removed << row if matches
                  matches
                end
              end
              cancel_media_receipts(removed)
            end
          end
          !!current
        end

        def collect_questions(route_key, route, conversation_id, workspace_id, reads:)
          rows = @bridge.pending(conversation_id, workspace_public_id: workspace_id, reads: reads)
          active = rows.map { |row| question_id(conversation_id, row) }
          @state.change do |document|
            document.fetch("questions").each do |id, question|
              if question.fetch("conversation_id") == conversation_id && !active.include?(id)
                question["resolved"] = true
              end
            end
          end
          rows.each do |row|
            id = question_id(conversation_id, row)
            known = @state.read.fetch("questions")[id]
            # A task can enter attention between the inbox and detail reads.
            # Its later actionable address completes the same question.
            upgrading = known && known.fetch("kind") == "local" && %w[ask approval].include?(row.fetch("kind"))
            next if known && !upgrading

            entry = (known || {}).merge(row).merge("route_key" => route_key, "conversation_id" => conversation_id)
            entry.delete("resolved") if upgrading
            text = if row.fetch("kind") == "approval"
              "Approval requested (#{id})\n#{row.fetch("question")}\n/approve #{id} or /deny #{id}"
            elsif row.fetch("kind") == "ask"
              "Question (#{id})\n#{row.fetch("question")}\nReply to this message, or use /answer #{id} your answer."
            else
              row.fetch("question")
            end
            markup = if row.fetch("kind") == "approval"
              { "inline_keyboard" => [[
                { "text" => "Approve", "callback_data" => "approve:#{id}" },
                { "text" => "Deny", "callback_data" => "deny:#{id}" },
              ]] }
            end
            # Question identity and its outgoing message are published together.
            @state.change do |document|
              delivery_key = "question:#{id}"
              if upgrading
                notice = document.fetch("deliveries")[delivery_key]
                # Only an unsent notice can be withdrawn. A sent or ambiguous
                # notice keeps its own receipt when the actual question arrives.
                document.fetch("deliveries").delete(delivery_key) if notice && notice.fetch("status") == "pending"
                delivery_key = "#{delivery_key}:#{row.fetch("kind")}"
              end
              document.fetch("questions")[id] = entry
              document.fetch("deliveries")[delivery_key] ||= route.slice("chat_id", "topic_id", "group").merge(
                "status" => "pending", "text" => text, "question_id" => id, "plain" => true, "reply_markup" => markup
              ).compact
            end
          end
        end

        def question_id(conversation_id, row)
          Digest::SHA256.hexdigest("#{conversation_id}:#{row.fetch("run_public_id")}:#{row.fetch("task_key")}")[0, 12]
        end

        def permitted_route?(route)
          !route.fetch("group") || @access.allowed_chat?(route.fetch("chat_id"))
        end

        def prune_receipts
          @state.change do |document|
            offset = document["offset"] || 0
            document.fetch("deliveries").delete_if do |key, entry|
              entry.fetch("status") == "sent" && (key.start_with?("turn:", "voice:") ||
                (key.start_with?("control:") && key.split(":").last.to_i < offset))
            end
            question_deliveries = document.fetch("deliveries").group_by { |_key, entry| entry["question_id"] }
            document.fetch("questions").delete_if do |id, question|
              deliveries = question_deliveries.fetch(id, [])
              removable = question["resolved"] && deliveries.any? &&
                deliveries.all? { |_key, entry| %w[pending sent].include?(entry.fetch("status")) }
              deliveries.each { |key, _entry| document.fetch("deliveries").delete(key) } if removable
              removable
            end
          end
        end

        def safely(operation)
          yield
        rescue Rho::ConfigurationError
          @connection = "configuration_error"
          raise
        rescue Client::Refused => error
          @delivery.throttle(error.retry_after) if error.retry_after
          @connection = error.code == 401 ? "unauthorized" : "retrying"
          @log.warn("telegram.refused", operation: operation, code: error.code)
          sleep(error.retry_after || (error.code == 401 ? 30 : 5))
        rescue Client::Unavailable, Rho::ConnectionError, CybrosAgent::TransportError => error
          @log.warn("telegram.unavailable", operation: operation, reason: error.class.name)
          sleep 5
        rescue CybrosAgent::Api::RateLimited => error
          @log.warn("telegram.nexus_throttled", operation: operation, retry_after: error.retry_after)
          sleep(error.retry_after || 5)
        rescue Rho::Error, CybrosAgent::Api::Error => error
          @log.warn("telegram.failed", operation: operation, reason: error.class.name)
          sleep 5
        end
    end
  end
end
