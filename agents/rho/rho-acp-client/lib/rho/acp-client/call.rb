require "rho/runner"
require "rho/acp"
require_relative "policy"

module Rho
  module AcpClient
    # THE CALL — CHILD EVENTS → RHO. One `session/prompt` on the session's child,
    # drained on THIS thread — the worker holding the `ExecutionContext`,
    # where `report_progress` works; the connection's reader thread only
    # parses. The child's `agent_message_chunk`s become the turn's text
    # (per `messageId`); a `tool_call`/`tool_call_update` is one line
    # `[<agent>] <kind> <title> … <status>` into a rolling 4 KiB tail
    # handed WHOLE to the context (bash's `PROGRESS_TAIL_BYTES`); a `plan`
    # one line; `usage_update` the trailer's usage; the thought, command,
    # mode, config and info updates captured and ignored. A
    # `session/request_permission` is answered by the floor and the row's
    # policy (`Policy`), never parked; an `elicitation/create` declined
    # and quoted; `fs/*`, `terminal/*` and anything else -32601.
    #
    # CANCEL: the context's cancel signal sets a flag and never
    # blocks; the drain notices within a poll, sends `session/cancel`,
    # gives the child one second of the pool's grace for its answer, and
    # returns through the runner's own `Cancelled` — the child stays
    # alive, its row survives, and the table's thread logs the answer
    # that lands after. THE WALL is the row's `timeout_ms` measured here
    # (the announced park is the longest row's), and the context's own
    # DEADLINE is the same wall: the cancel line, then the group KILLED
    # and reaped, the row gone — the answer data.
    #
    # The result: the turn's text under the runner's caps (the overflow
    # names the capture), one trailer line, the structure for the UI, and
    # the capture as a `resource_link`.
    class Call
      POLL_SECONDS = 0.1
      CANCEL_GRACE_SECONDS = 1.0
      PROGRESS_TAIL_BYTES = Rho::Runner::Tools::Bash::PROGRESS_TAIL_BYTES
      Methods = Rho::Acp::Methods
      Update = Methods::SessionUpdate
      StopReason = Methods::StopReason
      TRACKED_FIELDS = %w[title kind status rawInput locations content].freeze
      # Stop words of rho's own in the trailer, beside the spec's.
      STOP_EXITED = "exited".freeze
      STOP_TIMED_OUT = "timed_out".freeze
      STOP_REFUSED = "refused".freeze

      def initialize(session:, prompt:, env:, home:, log:, clock:)
        @session = session
        @child = session.child
        @row = session.child.row
        @prompt = prompt
        @env = env
        @home = home
        @log = log
        @clock = clock
        @text = +""
        @tail = +""
        @message_id = nil
        @calls = 0
        @refused = 0
        @usage = nil
        @asks = []
        @cancel_requested = false
        @cancel_sent_at = nil
      end

      def run
        @child.hold(@env) do
          @session.calls += 1
          @session.last_prompt_at = @clock.call
          pending = @child.request(Methods::SESSION_PROMPT, {
            "sessionId" => @session.acp_id,
            "prompt" => [{ "type" => Methods::ContentBlock::TEXT, "text" => @prompt.to_s.scrub }],
          })
          wall = monotonic + (@row.timeout_ms / 1000.0)
          outcome = Rho::Runner::ExecutionContext.with_cancel_signal(-> { @cancel_requested = true }) do
            drain(pending, wall)
          end
          settle(outcome, pending)
        end
      end

      private

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # The run_public_id: an event a slice, the four exits. The reader queues the
        # child's updates in wire order and resolves the prompt's answer
        # after them, so a done answer means every update before it is
        # already queued: they are read before the turn is settled.
        def drain(pending, wall)
          loop do
            event = @child.receive(timeout: POLL_SECONDS)
            handle(event) if event
            if pending.done?
              while (queued = @child.receive(timeout: 0))
                handle(queued)
              end
              return :done
            end
            return :died if @child.exited? || @child.closed?

            if @cancel_requested && @cancel_sent_at.nil?
              return :deadline if Rho::Runner::ExecutionContext.current&.reason == :deadline

              send_cancel
            end
            return :cancelled if @cancel_sent_at && monotonic - @cancel_sent_at > CANCEL_GRACE_SECONDS
            return :wall if monotonic > wall
          end
        end

        def send_cancel
          @child.notify(Methods::SESSION_CANCEL, { "sessionId" => @session.acp_id })
          @cancel_sent_at = monotonic
          @log&.info("acp.cancel_sent", agent: @row.key, session: @session.id,
            reason: Rho::Runner::ExecutionContext.current&.reason)
        rescue Rho::Acp::Closed
          @cancel_sent_at = monotonic
        end

        def settle(outcome, pending)
          case outcome
          when :done then finished(pending)
          when :died then died
          when :wall then wall!
          when :deadline
            killed!("killed after a timed-out call")
            @env.raise_if_cancelled!
            wall!
          else
            @child.observe_late(pending, @session.id)
            @env.raise_if_cancelled!
            error("the delegation was cancelled", stop: StopReason::CANCELLED)
          end
        end

        def finished(pending)
          result = @child.await(pending, deadline: monotonic + CANCEL_GRACE_SECONDS, what: Methods::SESSION_PROMPT)
          stop = result.is_a?(Hash) ? result["stopReason"].to_s : ""
          case stop
          when StopReason::END_TURN, StopReason::MAX_TOKENS then ok(stop)
          when StopReason::CANCELLED
            @env.raise_if_cancelled! if @cancel_sent_at
            error("the agent cancelled the turn", stop: stop)
          else
            error("the delegation did not finish (stop reason #{stop.inspect})", stop: stop.empty? ? "unknown" : stop)
          end
        rescue Rho::Acp::RemoteError => remote
          return @env.raise_if_cancelled! || error("the delegation was cancelled", stop: StopReason::CANCELLED) if
            @cancel_sent_at && remote.code == Methods::ErrorCode::REQUEST_CANCELLED

          error("the agent answered #{remote.code}: #{@child.redact.call(remote.message)}", stop: STOP_REFUSED)
        rescue Unavailable, Refused
          died
        end

        # The child exited mid-turn: the sentence names the exit and the
        # tail; the row is gone.
        def died
          @child.settle(Children::SETTLE_SECONDS)
          description = @child.exited? ? "exited (#{@child.exit_description})" : "stopped answering"
          tail = @child.redact.call(@child.stderr_tail).strip
          clause = tail.empty? ? "" : "; its stderr ended: #{tail.lines.last.to_s.strip}"
          Children.retire(@child, reason: "exited during a delegation", log: @log)
          error("acp agent \"#{@row.key}\" #{description} during the delegation#{clause}", stop: STOP_EXITED)
        end

        def wall!
          begin
            @child.notify(Methods::SESSION_CANCEL, { "sessionId" => @session.acp_id }) if @cancel_sent_at.nil?
          rescue Rho::Acp::Closed
            nil
          end
          killed!("killed after a timed-out call")
          seconds = @row.timeout_ms / 1000.0
          seconds = seconds.to_i if seconds == seconds.to_i
          error("delegate_agent timed out after #{seconds} seconds: acp agent \"#{@row.key}\"'s process group was killed; " \
                "its sessions are gone", stop: STOP_TIMED_OUT)
        end

        def killed!(reason)
          Children.retire(@child, reason: reason, log: @log, kill: true)
        end

        # ---- the events ----

        def handle(event)
          case event
          when Rho::Acp::Connection::Inbound then inbound(event)
          when Rho::Acp::Wire::Notification then notification(event)
          else nil
          end
        end

        def inbound(request)
          return @child.refuse(request, Methods::ErrorCode::REQUEST_CANCELLED,
            Methods::ErrorCode::MESSAGES.fetch(Methods::ErrorCode::REQUEST_CANCELLED)) if request.cancelled?

          case request.method
          when Methods::SESSION_REQUEST_PERMISSION then permission(request)
          when Methods::ELICITATION_CREATE then elicitation(request)
          else @child.refuse(request, Methods::ErrorCode::METHOD_NOT_FOUND,
            Methods::ErrorCode::MESSAGES.fetch(Methods::ErrorCode::METHOD_NOT_FOUND))
          end
        end

        # THE RELAY: decided locally, one capture line and one log
        # fact per decision, never a park.
        def permission(request)
          params = Hash.try_convert(request.params) || {}
          decision = Policy.decide(params, tracked: @session.tool_calls, row: @row, home: @home)
          @refused += 1 if decision.by == "floor"
          @child.answer(request, decision.outcome)
          @child.capture&.note("permission", agent: @row.key, session: @session.id, kind: decision.kind,
            decision: decision.decision, by: decision.by, reason: decision.reason,
            tool_call: params.dig("toolCall", "toolCallId"))
          # The reason quotes the child's own text (a command excerpt), so
          # it passes the row's redaction before it reaches the log.
          @log&.info("acp.permission", agent: @row.key, kind: decision.kind, decision: decision.decision, by: decision.by,
            reason: decision.reason && @child.redact.call(decision.reason), session: @session.id)
        end

        def elicitation(request)
          params = Hash.try_convert(request.params) || {}
          @asks << params["message"].to_s.scrub
          @child.answer(request, { "action" => Methods::ElicitationAction::DECLINE })
        end

        def notification(notice)
          return unless notice.method == Methods::SESSION_UPDATE

          params = Hash.try_convert(notice.params) || {}
          return unless params["sessionId"] == @session.acp_id

          update = Hash.try_convert(params["update"]) || {}
          case update[Methods::SESSION_UPDATE_DISCRIMINATOR]
          when Update::AGENT_MESSAGE_CHUNK then chunk(update)
          when Update::TOOL_CALL then tool_call(update)
          when Update::TOOL_CALL_UPDATE then tool_call_update(update)
          when Update::PLAN then plan(update)
          when Update::USAGE_UPDATE then @usage = update.except(Methods::SESSION_UPDATE_DISCRIMINATOR)
          else nil
          end
        end

        def chunk(update)
          content = Hash.try_convert(update["content"]) || {}
          return unless content["type"] == Methods::ContentBlock::TEXT

          text = content["text"].to_s.scrub
          message_id = update["messageId"]
          if !@message_id.nil? && message_id != @message_id && !@text.empty? && !@text.end_with?("\n")
            @text << "\n"
            @tail << "\n"
          end
          @message_id = message_id
          @text << text
          @tail << text
          progress!
        end

        def tool_call(update)
          id = update["toolCallId"].to_s
          tracked = update.slice(*TRACKED_FIELDS)
          tracked["status"] ||= Methods::ToolCallStatus::PENDING
          @session.tool_calls[id] = tracked
          @calls += 1
          line!(id)
        end

        def tool_call_update(update)
          id = update["toolCallId"].to_s
          known = @session.tool_calls[id] || {}
          @session.tool_calls[id] = known.merge(update.slice(*TRACKED_FIELDS).compact)
          line!(id)
        end

        def line!(id)
          call = @session.tool_calls.fetch(id)
          push_line("[#{@row.key}] #{call["kind"]} #{call["title"]} … #{call["status"]}")
        end

        def plan(update)
          entries = Array(update["entries"]).select { |entry| entry.is_a?(Hash) }
          words = entries.map { |entry| "#{entry["status"]} #{entry["content"]}" }.join("; ")
          push_line("[#{@row.key}] plan: #{words}")
        end

        def push_line(line)
          @tail << "\n" unless @tail.empty? || @tail.end_with?("\n")
          @tail << line.to_s.scrub << "\n"
          progress!
        end

        # The newest tail, whole, cut at a line boundary (bash's rule).
        def progress!
          text = @tail
          if text.bytesize > PROGRESS_TAIL_BYTES
            cut = text.byteslice(text.bytesize - PROGRESS_TAIL_BYTES, PROGRESS_TAIL_BYTES).scrub("")
            index = cut.index("\n")
            text = index.nil? ? cut : cut[(index + 1)..]
          end
          @env.report_progress(@child.redact.call(text))
        end

        # ---- the result ----

        def ok(stop) = Rho::Runner::Result.ok(body(stop), structure(stop), files: files)

        def error(sentence, stop:)
          Rho::Runner::Result.error(body(stop, sentence), structure(stop), files: files)
        end

        def files = @child.capture ? [@child.capture.path] : []

        def body(stop, sentence = nil)
          parts = []
          text = @child.redact.call(@text).strip
          unless text.empty?
            window = Rho::Runner::Truncation.truncate_head(text)
            parts << window.content
            if window.truncated
              parts << "[Showing lines 1-#{window.output_lines} of #{window.total_lines}. Full text: #{@child.capture&.path}]"
            end
          end
          parts << sentence if sentence
          @asks.each { |ask| parts << "the agent asked: #{@child.redact.call(ask)} — declined; prompt the session again with an answer" }
          parts << trailer(stop)
          parts.join("\n\n")
        end

        def trailer(stop)
          "session: #{@session.id} · stop: #{stop} · calls: #{@calls} (#{@refused} refused by the floor) · " \
            "capture: #{@child.capture&.path}"
        end

        def structure(stop)
          { "agent" => @row.key, "session" => @session.id, "stopReason" => stop, "calls" => @calls, "refused" => @refused,
            "usage" => @usage && @child.redact.structure(@usage) }
        end
    end
  end
end
