require "digest"

module Rho
  module T3
    class Work
      POLL_SECONDS = 1

      def initialize(settings:, session:, env:, home:, bridge: Bridge.new(settings), sleeper: -> { sleep POLL_SECONDS })
        @settings, @session, @env, @home, @bridge, @sleeper = settings, session, env, home, bridge, sleeper
        @records = session.records
        @context = session.context
      end

      def delegate(args)
        raise Error, "coding delegation requires claim-scoped questions" unless @context.orchestration

        prompt = args.fetch("prompt")
        @row = if args["work_id"]
          resume(args.fetch("work_id"), prompt, args)
        else
          launch(prompt, args.fetch("title", "Coding assignment"), args)
        end
        wait
      rescue Rho::Runner::ExecutionContext::Cancelled
        stop_native if @row && @row.value.fetch("owner") == @session.owner
        raise
      rescue Error, CybrosAgent::Error, Rho::Runner::ClaimOrchestration::Failure => error
        raise if @row.nil? || @row.value.fetch("owner") != @session.owner

        detail = case stop_native
        when "settled" then "The existing native work is settled."
        when "requested" then "Stop was submitted for the existing native work."
        else "Native Stop could not be confirmed."
        end
        raise error.exception("#{error.message}\nCoding work #{@row.public_id}. #{detail} Observe or stop this work; do not launch a replacement automatically."), cause: nil
      end

      def control(args)
        if args.fetch("action") == "agents"
          return Rho::Runner::Result.ok(JSON.generate({ "agents" => catalog.report, "default_agent" => @settings.default_agent }))
        end
        if args.fetch("action") == "list"
          return Rho::Runner::Result.ok(JSON.generate({ "work" => @records.list }))
        end

        @row = @records.fetch(args.fetch("work_id"))
        verify_environment
        case args.fetch("action")
        when "observe" then result(projection)
        when "stop"
          current = projection
          interrupt(current)
          # The delegating handler may be waiting inside a durable question,
          # so native interruption alone cannot release its Nexus task.
          @session.cancel(@row.value.fetch("owner"))
          Rho::Runner::Result.ok("Stop requested for coding work #{@row.public_id}; completion is observed separately.")
        when "steer"
          raise Error, "the coding task no longer owns active work" unless @session.active?(@row.value.fetch("owner"))

          current = projection
          raise Error, "coding work has no active run to steer" if current.terminal? || current.run.nil?
          verify_permissions(current)

          send_message(args.fetch("prompt"), mode: { "type" => "steer_active", "targetRunId" => current.run.fetch("id") })
          Rho::Runner::Result.ok("Steering submitted for coding work #{@row.public_id}.")
        when "forget"
          current = projection
          raise Error, "stop and settle coding work before forgetting its continuation" unless current.terminal?
          raise Error, "the owning Nexus task is still active" if @session.active?(@row.value.fetch("owner"))

          @records.delete(@row)
          Rho::Runner::Result.ok("Removed the coding continuation; committed task results remain in history.")
        else raise Error, "unknown coding work action"
        end
      end

      private

        def catalog
          Catalog.new(providers: @bridge.call("server.getConfig", {}).fetch("providers"))
        rescue KeyError, TypeError, NoMethodError
          raise Error, "The coding service returned an incomplete agent directory", cause: nil
        end

        def launch(prompt, title, args)
          previous = @records.find(@session.key)
          if previous
            @row = previous
            verify_environment
            verify_requested_selection(args)
            recovered = projection
            unless recovered.messages.any? { |message| message.fetch("id") == @row.value.fetch("message") }
              raise Uncertain, "the original launch has no accepted message; no duplicate was launched"
            end
            return @row
          end

          selected = catalog.select(agent: args["agent"] || @settings.default_agent, model: args["model"])
          @row = @records.create(@session.key, {
            "thread" => SecureRandom.uuid_v7, "command" => SecureRandom.uuid_v7,
            "message" => SecureRandom.uuid_v7, "owner" => @session.owner,
            "title" => title,
            "environment" => @settings.environment.merge("modelSelection" => selected.native),
            "selection" => selected.report,
          })
          @context.raise_if_cancelled!
          begin
            @bridge.call("orchestration.launchThread", @row.value.fetch("environment").except("url").merge(
              "threadId" => @row.value.fetch("thread"), "commandId" => @row.value.fetch("command"),
              "title" => title, "initialMessage" => { "messageId" => @row.value.fetch("message"), "text" => prompt, "attachments" => [] }
            ))
          rescue Uncertain
            recovered = projection
            unless recovered.messages.any? { |message| message.fetch("id") == @row.value.fetch("message") }
              raise Uncertain, "the original launch has no accepted message; no duplicate was launched"
            end
          end
          @row
        end

        def resume(id, prompt, args)
          @row = @records.fetch(id)
          verify_environment
          verify_requested_selection(args)
          current = projection
          verify_permissions(current)
          if @row.value.fetch("owner") == @session.owner
            # A replay may have sent its continuation already. Read its message
            # before doing anything; no automatic retry can create a second run.
            reconcile_message(current)
          else
            raise Error, "coding work is still owned by an active task; use steer" unless current.terminal?
            raise Error, "the prior Nexus task is still active" if @session.active?(@row.value.fetch("owner"))

            @row = @records.update(@row, owner: @session.owner, pending_command: nil)
            send_message(prompt, mode: { "type" => "start_immediately" })
          end
          @row
        end

        def verify_environment
          unless @row.value.fetch("environment").except("modelSelection") == @settings.environment
            raise Error, "coding work belongs to a different environment or configuration; restore its original connection"
          end
        end

        def verify_requested_selection(args)
          selected = @row.value.fetch("selection")
          agent_matches = !args["agent"] || [selected.fetch("agent"), selected.fetch("harness")].any? { |name| name.casecmp?(args.fetch("agent")) }
          model_matches = !args["model"] || args.fetch("model") == selected.fetch("model")
          unless agent_matches && model_matches
            raise Error, "Existing coding work keeps its original agent and model; start new work for a different selection"
          end
        end

        def projection(cancelled: true)
          raw = @bridge.call("orchestration.getThreadProjection", { "threadId" => @row.value.fetch("thread") }, cancelled: cancelled)
          value = Projection.new(raw: raw)
          unless value.thread.fetch("id") == @row.value.fetch("thread") && value.thread.fetch("projectId") == @row.value.dig("environment", "projectId")
            raise Error, "T3 projection does not match the accepted coding environment"
          end
          value
        end

        def verify_permissions(current)
          # Preserve the selected native mode and environment. That mode does
          # not promise an identifiable approval callback for every operation.
          unless current.thread.fetch("runtimeMode") == "approval-required"
            raise Error, "the native permission mode changed; restore approval-required before continuing"
          end
          selected = @row.value.fetch("environment").fetch("modelSelection")
          unless current.thread.fetch("modelSelection").slice("instanceId", "model") == selected &&
              current.model_selection.slice("instanceId", "model") == selected
            raise Error, "the native model or provider changed; restore the accepted coding environment"
          end
          placement = current.thread.slice("branch", "worktreePath")
          if @row.value.key?("placement")
            raise Error, "the native branch or worktree changed; restore the accepted coding environment" unless @row.value.fetch("placement") == placement
          else
            @row = @records.update(@row, placement: placement)
          end
        end

        def wait
          loop do
            @context.raise_if_cancelled!
            current = projection
            @context.raise_if_cancelled!
            verify_permissions(current)
            return finish(current) if current.terminal?

            @env.report_progress("#{@row.value.fetch("selection").fetch("agent")} work #{@row.public_id}: #{current.run&.fetch("status") || "starting"}")
            current.requests.each { |request| respond(current, request) }
            @sleeper.call
          end
        end

        def respond(current, request)
          unless current.request_live?(request)
            raise Error, "native request #{request.fetch("id")} is no longer resumable; the saved projection is not a live callback"
          end
          item = current.request_item(request)
          raise Error, "native request details are unavailable" unless item

          if request.fetch("kind") == "user_input"
            # Providers may present consent as an ordinary question without an
            # action identity. Preserve that wire meaning; do not infer a tool.
            answers = item.fetch("questions").to_h do |question|
              [question.fetch("id"), answer_question(request, question)]
            end
            payload = { "answers" => answers }
          else
            reason = floor_refusal(current, request)
            if item.key?("options") && !item.fetch("options").any? { |option| option.fetch("decision") == "accept" }
              reason ||= "the native adapter offers no one-shot approval"
            end
            decision = reason ? "decline" : ask(request, "approval", approval_prompt(current, request, item), %w[accept decline])
            decision = "decline" unless decision == "accept"
            payload = { "decision" => decision }
            @env.report_progress("Native action refused: #{reason}") if reason
          end
          @context.raise_if_cancelled!
          # Re-read the live callback after a possibly long Human wait. A T3
          # restart may expire it while Nexus's durable question survives.
          fresh = projection
          live = fresh.requests.find { |candidate| candidate.fetch("id") == request.fetch("id") }
          unless live && fresh.request_live?(live)
            raise Error, "native request expired while awaiting an answer; no permission was forwarded"
          end
          @bridge.call("orchestration.dispatchCommand", {
            "type" => "runtime-request.respond", "commandId" => command_id("response:#{request.fetch("id")}"),
            "threadId" => @row.value.fetch("thread"), "requestId" => request.fetch("id"), **payload,
          })
        end

        def answer_question(request, question)
          options = question.fetch("options")
          labels = options.map { |option| option.fetch("label") }
          prompt = question.fetch("question")
          if question["multiSelect"]
            prompt += "\nReturn a JSON array of selected option labels: #{JSON.generate(labels)}."
          end
          answer = ask(request, question.fetch("id"), prompt, question["multiSelect"] ? [] : labels)
          selected = question["multiSelect"] ? JSON.parse(answer).map(&:to_s) : [answer]
          values = selected.map do |label|
            option = options.find { |candidate| candidate.fetch("label") == label }
            if !option && !labels.empty? && question["allowCustomAnswer"] == false
              raise Error, "the answer must use an offered native choice"
            end
            option ? option.fetch("value", label) : label
          end
          question["multiSelect"] ? values : values.first
        rescue JSON::ParserError, NoMethodError
          raise Error, "the native multiple-choice answer must be a JSON array of option labels", cause: nil
        end

        def approval_prompt(current, request, item)
          prompt = item.fetch("prompt", "Approve the native coding agent's requested action?")
          action = current.requested_action(request)
          action ? "#{prompt}\nNative action: #{JSON.generate(action.slice("type", "input", "fileName", "changes"))}" : prompt
        end

        def floor_refusal(current, request)
          # Approval prose may contain only a reason. Resolve the owning action
          # through native identity; unrelated neighboring tool items cannot
          # stand in for the command or files being authorized.
          action = current.requested_action(request)
          case request.fetch("kind")
          when "command"
            return "the native command is unavailable for the permission floor" unless action && action.fetch("type") == "command_execution"

            Rho::Extensions::Guard.refusal("bash", { "command" => action.fetch("input") }, @home)
          when "file-change"
            return "the native edit paths are unavailable for the permission floor" unless action && action.fetch("type") == "file_change"

            cwd = current.request_cwd(request)
            return "the native edit directory is unavailable" unless cwd

            paths = action.fetch("changes", []).flat_map { |change| [change.fetch("path"), change["oldPath"]] }.compact
            paths << action.fetch("fileName") if paths.empty?
            paths.filter_map { |path| Rho::Extensions::Guard.refusal("write", { "path" => File.expand_path(path, cwd) }, @home) }.first
          when "file-read"
            nil
          when "permission", "mcp-elicitation"
            "the native request does not identify a one-shot command or edit"
          else
            "the native request kind cannot be approved through this bridge"
          end
        end

        def ask(request, part, prompt, options)
          answer = @context.orchestration.ask(key: "t3_#{Digest::SHA256.hexdigest("#{request.fetch("id")}:#{part}")[0, 32]}",
            prompt: "Coding work #{@row.public_id}\n#{prompt}", options: options.empty? ? nil : options)
          unless answer.fetch("status") == "completed" && !answer["is_error"]
            raise Error, "the coding question did not receive a completed answer"
          end
          answer.fetch("content").select { |block| block.fetch("type") == "text" }.map { |block| block.fetch("text") }.join("\n")
        end

        def send_message(prompt, mode:)
          pending = @row.value["pending_command"]
          if pending && pending.fetch("key") == @session.key
            reconcile_message(projection)
            return
          end
          pending = { "key" => @session.key, "message" => SecureRandom.uuid_v7, "command" => SecureRandom.uuid_v7 }
          @row = @records.update(@row, pending_command: pending)
          @context.raise_if_cancelled!
          @bridge.call("orchestration.dispatchCommand", {
            "type" => "message.dispatch", "threadId" => @row.value.fetch("thread"), "commandId" => pending.fetch("command"),
            "createdBy" => "agent", "creationSource" => "server",
            "messageId" => pending.fetch("message"), "text" => prompt, "attachments" => [], "dispatchMode" => mode,
          })
        rescue Uncertain
          reconcile_message(projection)
        end

        def reconcile_message(current)
          pending = @row.value["pending_command"]
          unless pending && current.messages.any? { |message| message.fetch("id") == pending.fetch("message") }
            raise Uncertain, "the continuation message was not found; no duplicate was sent"
          end
        end

        def command_id(purpose)
          # Native command ids are opaque strings; a deterministic task-local
          # coordinate lets T3 reconcile transport ambiguity without re-execution.
          "rho:#{@row.value.fetch("thread")}:#{purpose}"
        end

        def interrupt(current, cancelled: true)
          return if current.run.nil? || current.terminal?

          @bridge.call("orchestration.dispatchCommand", {
            "type" => "run.interrupt", "threadId" => @row.value.fetch("thread"),
            "commandId" => command_id("stop:#{current.run.fetch("id")}"), "runId" => current.run.fetch("id"),
            "holdQueue" => true, "reason" => "The owning rho task was stopped",
          }, cancelled: cancelled)
        end

        def stop_native
          return unless @row

          current = projection(cancelled: false)
          if current.terminal?
            "settled"
          else
            interrupt(current, cancelled: false)
            "requested"
          end
        rescue Error
          @env.report_progress("Coding Stop could not be confirmed; work #{@row.public_id} needs reconciliation.")
          "uncertain"
        end

        def finish(current)
          @context.raise_if_cancelled!
          result(current, capture: true)
        end

        def result(current, capture: false)
          report = current.report.merge("work_id" => @row.public_id, **@row.value.fetch("selection").slice("agent", "harness"))
          files = []
          if capture
            directory = @env.ensure_artifacts_dir!
            report["checks"] = complete_checks(current)
            begin
              diff = @bridge.call("orchestration.getFullThreadDiff", { "threadId" => current.thread.fetch("id"), "toTurnCount" => current.run.fetch("ordinal"), "ignoreWhitespace" => false })
              path = File.join(directory, "coding-#{@row.public_id}.diff")
              File.write(path, diff.fetch("diff"))
              files << path
            rescue Error
              report["limitation"] = "Final diff could not be read; native result and reported checks remain available."
            end
            path = File.join(directory, "coding-#{@row.public_id}.json")
            File.write(path, JSON.pretty_generate(report))
            files.unshift(path)
          end
          text = JSON.generate(report)
          window = Rho::Runner::Truncation.truncate_head(text)
          Rho::Runner::Result.new(content: window.content, structured_content: report.except("text", "checks", "workers"),
            is_error: current.terminal? && current.run.fetch("status") != "completed", files: files, files_required: capture)
        end

        def complete_checks(current)
          current.items.select { |item| item.fetch("type") == "command_execution" }.map do |item|
            if item["outputOmitted"]
              begin
                full = @bridge.call("orchestration.getTurnItem", { "threadId" => current.thread.fetch("id"), "itemId" => item.fetch("id") })
                item = full.fetch("item") || item
              rescue Error
                # The original omitted marker remains visible in the capture;
                # inability to fetch one log never invents a successful check.
              end
            end
            item.slice("input", "output", "exitCode", "outputIndicatesFailure", "outputOmitted")
          end
        end
    end
  end
end
