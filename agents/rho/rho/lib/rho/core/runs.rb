module Rho
  class Core
    # THE RUN PRIMITIVES: the rows a daemon follows, ONE run's events
    # pushed, its result, and every verb that moves a run or a task — the
    # Ops extension's routes (`rho.ops` keeps the routes; the capability
    # is the core's). Each is one route, answered as the document or
    # raised as the daemon's sentence. The watch (poll + print) and the
    # run (open + follow + print + exit) are compositions of these, in
    # the surfaces.
    module Runs
      # The row the daemon follows for a host id — its own, or the
      # conversation whose turn the run id backs or backed (`run_public_ids` is
      # every run the follower saw). A host the daemon is not following
      # is the ordinary state after a restart, and the sentence says so.
      def follower_row(public_id)
        # Side hosts are hidden from the default listing, but an explicit
        # host or run id can still follow their execution.
        [false, true].each do |side|
          row = followers(side: side).find { |entry| entry["public_id"] == public_id || Array(entry["run_public_ids"]).include?(public_id) }
          return row if row
        end
        raise Rho::Error, "this daemon is not following #{public_id}"
      end

      # Local feed followers are independent of the kernel's retained runs.
      def followers(side: false)
        path = side ? "/followers?side=1" : "/followers"
        Array(parse(get(require_daemon, path))["followers"])
      end

      def runs(status: nil, attention: nil)
        query = {}
        query["status"] = Array(status).join(",") unless status.nil?
        query["attention"] = attention unless attention.nil?
        path = query.empty? ? "/runs" : "/runs?#{URI.encode_www_form(query)}"
        Array(parse(get(require_daemon, path, budget: Budget::KERNEL_ROUND_TRIP))["runs"])
      end

      # ONE SUBSCRIPTION to a host's events (`GET /followers/follow`): server-sent
      # events parsed the small way they are specified — a blank line ends
      # a frame, `event:` names it, `data:` carries it — each yielded as
      # `(type, payload)`. THE DEADLINE IS THE SOCKET'S: the
      # read timeout is the remaining budget, re-armed after every chunk,
      # so a quiet stream (the daemon's heartbeat is twenty seconds apart)
      # cannot outlive it; it fires as `Deadline`. No deadline waits forever.
      def follower_events(public_id, deadline: nil)
        daemon = require_daemon
        uri = URI.join(daemon.fetch("endpoint"), "/followers/follow?#{URI.encode_www_form("public_id" => public_id)}")
        message = Net::HTTP::Get.new(uri)
        message["Authorization"] = "Bearer #{daemon["bearer"]}" if daemon["bearer"]
        message["Accept"] = "text/event-stream"
        ends = deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
        remaining = -> { ends && [ends - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.001].max }

        Net::HTTP.start(uri.host, uri.port, open_timeout: Budget::LOCAL.open, read_timeout: remaining.call,
          max_retries: 0) do |http|
          http.request(message) do |response|
            refuse(response, parse(response), "the daemon refused the follow") unless response.code.to_i == 200

            frame = +""
            response.read_body do |chunk|
              http.read_timeout = remaining.call if ends
              frame << chunk
              while (split = frame.index("\n\n"))
                deliver_frame(frame.slice!(0, split + 2)) { |type, payload| yield(type, payload) }
              end
            end
          end
        end
      rescue Net::ReadTimeout
        raise Deadline, "timed out following #{public_id} after #{deadline} s"
      rescue Net::OpenTimeout, IOError, SystemCallError, EOFError => error
        raise Rho::ConnectionError, "cannot reach the local daemon (#{error.class})"
      end

      # What a run produced: `status` and the deliverable's `output`.
      def result(public_id)
        query = URI.encode_www_form("public_id" => public_id)
        response = get(require_daemon, "/runs/result?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the result") unless response.code.to_i == 200

        document.fetch("result")
      end

      # After a restart, or on a second machine watching work the first
      # one started. Answers the document (`run`, the row). With
      # `host_type: "conversation"` the id names a
      # CONVERSATION — a row the bounded store forgot, a thread an editor
      # reopens — and the daemon follows its own feed, fetching no run;
      # the document is then `conversation` and the run.
      def attach(public_id, live: true, host_type: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "live" => live }
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["host_type"] = host_type unless host_type.nil?
        follower_verb("attach", body, "the daemon refused to attach to the host")
      end

      # The key is optional: the daemon reads the trace with the kernel's
      # own rule and refuses when two tasks qualify. Answers the task row.
      # Model, effort and enablement can change independently; omitted
      # controls keep the failed step's selection on the same model.
      def retry(public_id, task_key = nil, model: nil, reasoning_effort: nil, reasoning_enabled: nil, workspace_public_id: nil)
        repair("retry", public_id, task_key, { "model" => model, "reasoning_effort" => reasoning_effort,
          "reasoning_enabled" => reasoning_enabled, "workspace_public_id" => workspace_public_id }.compact)
      end

      def abandon(public_id, task_key = nil, workspace_public_id: nil)
        repair("abandon", public_id, task_key, { "workspace_public_id" => workspace_public_id }.compact)
      end

      # THE APPROVAL VERBS: the key is always named. `always`/
      # `match` ride the body as themselves; the
      # daemon derives the grant and answers it beside the task
      # (`task`, and `grant` when one was asked for).
      def approve(public_id, task_key, always: nil, match: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "task_key" => task_key }
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["always"] = true if always
        body["match"] = match unless match.nil?
        run_verb("approve", body, "the daemon refused to approve the call")
      end

      def deny(public_id, task_key, reason: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "task_key" => task_key }
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["reason"] = reason unless reason.nil?
        run_verb("deny", body, "the daemon refused to deny the call")
      end

      # A model's own `ask` is tokenless: without `token` the daemon commits
      # it on the executor plane as its own inbox row, falling to the
      # member door once for a row that is nobody's; a
      # client-authored await needs the `resolution_token` its append
      # receipt returned. Answers the `answered` row (with the `door`).
      def answer(public_id, task_key, content, outcome: nil, token: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "task_key" => task_key, "content" => content }
        body["workspace_public_id"] = workspace_public_id unless workspace_public_id.nil?
        body["outcome"] = outcome unless outcome.nil?
        body["resolution_token"] = token unless token.nil?
        response = post(require_daemon, "/answer", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        return document.fetch("answered") if response.code.to_i == 200

        refuse(response, document, "the daemon refused to answer")
      end

      # THE DAEMON'S PENDING ROWS: the `ask` and
      # `approval` rows of its own inbox through one `GET /asks` — a kernel
      # read. A daemon that refuses the read (no executor plane yet), or
      # answers something that is not the inbox (a daemon loaded without
      # the Ops routes, whose webui answers a page), raises: the inbox is
      # not a fact it holds.
      def asks
        response = get(require_daemon, "/asks", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the inbox") unless response.code.to_i == 200
        begin
          asks = document.fetch("asks")
        rescue KeyError, NoMethodError, TypeError
          raise Rho::Error, "the daemon answered no inbox"
        end

        Array(asks)
      end

      # THE SESSION GRANTS: `grants`, and `declared`
      # (the declared list's size against the kernel's bound).
      def rules
        response = get(require_daemon, "/rules", budget: Budget::LOCAL)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the rules") if document.key?("error")

        document
      end

      def pause(public_id, force: nil, workspace_public_id: nil)
        body = { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact
        body["force"] = force unless force.nil?
        run_verb("pause", body, "the daemon refused to pause the run").fetch("run")
      end

      def resume(public_id, workspace_public_id: nil)
        run_verb("resume", { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact, "the daemon refused to resume the run").fetch("run")
      end

      # The transcript feed held open for a followed host, or released.
      def subscribe(public_id)
        follower_verb("subscribe", { "public_id" => public_id }, "the daemon refused to subscribe")
      end

      def unsubscribe(public_id)
        follower_verb("unsubscribe", { "public_id" => public_id }, "the daemon refused to unsubscribe")
      end

      # The record, not the run: `stop` is how a run ends.
      def delete_run(public_id)
        run_verb("delete", { "public_id" => public_id }, "the daemon refused to delete the run")
      end

      # One task, whole: the question an await is asking, the arguments a
      # tool call was given, its output, its addressee.
      def task(public_id, task_key)
        query = URI.encode_www_form("public_id" => public_id, "task_key" => task_key)
        response = get(require_daemon, "/runs/task?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the task") unless response.code.to_i == 200

        # A 200 without the row is not a task read — a scripted double, a
        # daemon whose route is another's: the reader decides what that is.
        document["task"] || raise(Rho::Error, "the daemon answered no task")
      end

      # THE THREAD: the mainline newest-first from the kernel as a page
      # (`rounds`, `has_older`, `next_before`); `prefix` pages the branch
      # under that call instead.
      def transcript(public_id, limit: nil, before: nil, prefix: nil, workspace_public_id: nil)
        query = { "public_id" => public_id, "workspace_public_id" => workspace_public_id }.compact
        query["limit"] = limit.to_s unless limit.nil?
        query["before"] = before unless before.nil?
        query["prefix"] = prefix unless prefix.nil?
        response = get(require_daemon, "/runs/transcript?#{URI.encode_www_form(query)}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the transcript") if document.key?("error")

        document.fetch("transcript")
      end

      # The picture: `mermaid`, and the nodes and edges behind it.
      def graph(public_id)
        query = URI.encode_www_form("public_id" => public_id)
        response = get(require_daemon, "/runs/graph?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the graph") if document.key?("error")

        document.fetch("graph")
      end

      # THE BYTES A ROUND OR A TURN WAS SENT: `selector` is
      # `task_key` (a run and a key) or `turn` (a conversation and a turn
      # id); the sealed `request_options` and `entries`.
      def request_bytes(public_id, selector, value)
        query = URI.encode_www_form("public_id" => public_id, selector => value)
        response = get(require_daemon, "/runs/request?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the request") if document.key?("error")

        document.fetch("request")
      end

      # GROW A RUN: the steps as the door reads them; the `receipt`.
      def append(public_id, steps:)
        run_verb("append", { "public_id" => public_id, "steps" => steps }, "the daemon refused to append")
          .fetch("receipt")
      end

      # How far along: `phases`, `current`, `background`, `spend`.
      def phases(public_id)
        query = URI.encode_www_form("public_id" => public_id)
        response = get(require_daemon, "/runs/phases?#{query}", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read the phases") if document.key?("error")

        document.fetch("phases")
      end

      # THE RELAY: a tool call addressed to ONE runner as a
      # one-task run the daemon authors, starts, waits for and answers
      # whole — `call_tool` (`public_id`, `task`), with the wait bounded by
      # the step's own clock (`Budget.for_tool_call`).
      def call_tool(runner, tool, input, timeout_ms:)
        body = { "runner_executor_public_id" => runner, "tool" => tool, "input" => input, "timeout_ms" => timeout_ms }
        response = post(require_daemon, "/runs/call_tool", body, budget: Budget.for_tool_call(timeout_ms))
        document = parse(response)
        refuse(response, document, "the daemon refused to call_tool the call") unless response.code.to_i == 200

        document.fetch("call_tool")
      end

      private

        def repair(verb, public_id, task_key, fields = {})
          body = { "public_id" => public_id }
          body["task_key"] = task_key unless task_key.nil?
          run_verb(verb, body.merge(fields), "the daemon refused to #{verb} the task").fetch("task")
        end

        # One `POST /runs/<verb>`: the document on 200/201, the sentence
        # otherwise.
        def run_verb(verb, body, refusal)
          response = post(require_daemon, "/runs/#{verb}", body, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          return document if [200, 201].include?(response.code.to_i)

          refuse(response, document, refusal)
        end

        def follower_verb(verb, body, refusal)
          response = post(require_daemon, "/followers/#{verb}", body, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          return document if [200, 201].include?(response.code.to_i)

          refuse(response, document, refusal)
        end

        def deliver_frame(raw)
          type = nil
          data = +""
          raw.each_line do |line|
            line = line.chomp
            next if line.empty? || line.start_with?(":")

            field, _, value = line.partition(":")
            value = value.sub(/\A /, "")
            type = value if field == "event"
            data << value if field == "data"
          end
          return if type.nil?

          yield(type, JSON.parse(data.empty? ? "{}" : data))
        rescue JSON::ParserError
          nil
        end
    end
  end
end
