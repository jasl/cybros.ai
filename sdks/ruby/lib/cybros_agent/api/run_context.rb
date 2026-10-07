module CybrosAgent
  module Api
    # ONE AGENT RUN, from the author's side: read its trace, grow it, and
    # drive its lifecycle.
    #
    # CREATED STOPPED, STARTED DELIBERATELY. `create` authors the seed
    # batch and spends nothing; `start` is what puts a model call on the
    # wire. The two are separate so a caller can inspect — or refuse —
    # what it just authored before it costs anything.
    #
    # THE GRAPH GROWS, IT NEVER CHANGES. `append` places steps in written
    # order after the run's answer; nothing here edits or removes one, and
    # nothing here authors an edge — that is the kernel's, which is what
    # keeps the graph sound; `graph` reads it whole and
    # `phases` says how far it got. `expected_revision` is the optimistic fence for
    # an author holding its last receipt: a caller that lost a race gets
    # `stale_revision` rather than appending against a shape that moved. The
    # trace does not carry the counter, so an author that only read the
    # trace appends unfenced and relies on its idempotency key.
    #
    # WAITING IS THE CALLER'S. There is no blocking spelling here, for the
    # reason the runner half states: hiding a poll loop inside a method
    # hides the interval and the deadline from the only code that can
    # choose them. The one exception is `wait_for_tool_result`, and it hides
    # neither: the interval is its argument, and the deadline is the
    # request row's own — the kernel's sweep settles an unanswered request
    # at that deadline, so the poll always ends.
    class RunContext
      include RunProjections
      include Fields

      # THE ONE TASK of a request run: the key
      # `RunsContext#request` authors its seed under, and the key
      # `wait_for_tool_result` reads.
      TOOL_CALL_TASK_KEY = "call_tool".freeze
      DEFAULT_REQUEST_POLL_SECONDS = 1.0

      attr_reader :workspace_public_id, :run_public_id

      def initialize(dispatch:, workspace_public_id:, run_public_id:)
        @dispatch = dispatch
        @workspace_public_id = required_string_snapshot(workspace_public_id, "workspace_public_id")
        @run_public_id =
          required_string_snapshot(run_public_id, "run_public_id")
      end

      def fetch = shape(Run, @dispatch.call(path), "run")

      # Select the default for future Runner work. Existing tasks retain their
      # accepted target. Explicit nil clears the convenience default.
      def set_default_runner(executor_public_id:)
        binding = { "executor_public_id" => executor_public_id.nil? ? nil : required_string(executor_public_id, "executor_public_id") }
        shape(Run, @dispatch.call("#{path}/default_runner", method: :put, body: { "default_runner" => binding }), "run")
      end

      # The task-grained trace's single-task read — the one projection that
      # loads a body, which is how a caller retrieves a deliverable.
      def task(task_key)
        shape(RunTaskDetail, @dispatch.call("#{path}/tasks/#{required_string(task_key, "task_key")}"), "task")
      end

      # THE ANSWER TO A REQUEST: the one task read every
      # `poll` seconds until it is terminal, answered whole — `content`,
      # `structured_content`, `title`, `metadata`, and on a request that did
      # not complete the `error.key` a reader acts on (`tool_not_served`,
      # `tool_timeout`, `approval_denied`). Then the run it leaves: a tool
      # deliverable that did not complete holds the run `needs_attention`
      # by the kernel's rule for a person's run, and a one-task request
      # run has nobody to attend it — so the composition STOPS it (forced;
      # the settled row keeps its word) and no attention row lingers.
      #
      # THE BOUND. The request row's deadline is the kernel's: the step's
      # own `timeout_ms`, else the runner's announced park, else the kernel
      # default; an offline runner never claims and the sweep settles the
      # row `timed_out` at that deadline plus the sweep's minute. That is
      # what ends this poll by default, and it is why `patience` has no
      # number of its own: the task read carries no deadline, and a guess
      # here would be a second clock beside the kernel's. A caller that
      # will not wait for the kernel's names `patience` (seconds); when it
      # runs out the run is stopped the same way and the task read back
      # — a forced stop settles a dispatched row `canceled` at once — so
      # the answer is a terminal task either way.
      def wait_for_tool_result(poll: DEFAULT_REQUEST_POLL_SECONDS, patience: nil)
        interval = Float(poll)
        raise ArgumentError, "poll must be positive" unless interval.positive?
        deadline = patience.nil? ? nil : monotonic_now + Float(patience)

        stopped = false
        detail = task(TOOL_CALL_TASK_KEY)
        until detail.task.terminal?
          if deadline && !stopped && monotonic_now >= deadline
            stop
            stopped = true
          else
            sleep(interval)
          end
          detail = task(TOOL_CALL_TASK_KEY)
        end
        stop unless stopped || detail.task.status == "completed"
        detail
      end

      # GROW IT. `expected_revision` is the `revision` of the receipt
      # this envelope was decided against; a concurrent append then refuses
      # instead of interleaving. An envelope of `resolve` entries alone
      # places nothing and is legal; one with neither is refused here.
      def append(steps:, idempotency_key:, resolve: UNSET, expected_revision: UNSET)
        required_string(idempotency_key, "idempotency_key")
        raise ArgumentError, "steps must be an Array" unless steps.is_a?(Array)
        raise ArgumentError, "steps must be a non-empty Array, or resolve given" if
          steps.empty? && UNSET.equal?(resolve)

        body = fields(steps: Steps.envelope(steps), resolve:, expected_revision:)

        result = @dispatch.call_accepting(
          "#{path}/tasks", method: :post, body: body,
          headers: { "Idempotency-Key" => idempotency_key },
          success: [201, 200]
        )
        shape(AppendedTasks, result.body, "receipt")
      end

      # THE REPLAY WINDOW: strictly after `after`, ascending, with the
      # committed-max watermark a follower freezes to know its drain is
      # done. The limit is a hard reject on the server rather than a
      # clamp, so asking for more than it serves raises instead of quietly
      # returning less.
      #
      # NO BLOCKING SPELLING, for the reason the whole surface states:
      # hiding a poll loop inside a method hides the interval and the
      # deadline from the only code that can choose them.
      def events(after: nil, limit: nil)
        shape(ConversationEventPage, @dispatch.call("#{path}/events", params: query(after:, limit:)))
      end

      # THE THREAD, beside the trace's orchestration view. Without
      # `realtime:` a WINDOW, never a document: the mainline's rounds
      # newest-first behind an opaque cursor, returned in reading order,
      # each with the calls it read and the branches under them; with
      # `prefix:` a call key, the branch under that call in the same shape
      # (a page, never followed). With `realtime:` the same feed the
      # conversation's `transcript` opens, on the run's own channel — a
      # STANDALONE run only, since a conversation-hosted run's stream is its
      # conversation's: deltas while a round runs and the settled
      # `round`/`call` when a task terminalizes, every item under
      # `run_public_id` and `task_key`, a socket and NOTHING ELSE
      # (nothing on it is durable; the window is the recovery path). One
      # feed, one spelling: a page keyword beside `realtime:` is a
      # contradiction and raises.
      def transcript(realtime: nil, before: nil, limit: nil, prefix: nil)
        return transcript_window(before: before, limit: limit, prefix: prefix) if realtime.nil?
        unless before.nil? && limit.nil? && prefix.nil?
          raise ArgumentError, "transcript(realtime:) is a socket, not a page: drop before/limit/prefix"
        end

        Realtime::FeedSubscription.opener(
          client: realtime, channel: EVENTS_CHANNEL,
          params: {
            workspace_id: @workspace_public_id, run_id: @run_public_id,
            items: "transcript",
          },
          event: ->(message) { shape(TranscriptItem, message, "event") }
        )
      end

      # The picture: every node, every edge as task keys, and the Mermaid text
      # the kernel derived from them — the whole run at once, for debugging,
      # as e2e evidence, and for a UI to draw the workflow.
      def graph = shape(RunGraph, @dispatch.call("#{path}/graph"))

      # HOW FAR ALONG: the authored phases in write order, the one in
      # flight, the background work still to settle, and the spend — derived
      # by the kernel from the rows it already holds. Named `phases` for
      # what it answers: `progress` below is the host's ephemeral feed.
      def phases = shape(RunPhases, @dispatch.call("#{path}/phases"))

      # WHAT AN EXECUTOR IS DOING RIGHT NOW: the run's
      # `progress` feed — a `bash` tail under a claim, a process's output
      # under the run's binding — yielded as `ProgressFrame`s. A socket
      # and NOTHING ELSE: nothing on it is durable, nothing replays, a
      # late subscriber sees what follows. Its envelope is `{frame}`, which
      # is why the events mapper never sees one and this opener has its own.
      # A STANDALONE run only, as `transcript(realtime:)` is: a run-backed
      # run's frames ride its conversation's channel.
      def progress(realtime:)
        Realtime::FeedSubscription.opener(
          client: realtime, channel: EVENTS_CHANNEL,
          params: {
            workspace_id: @workspace_public_id, run_id: @run_public_id,
            items: "progress",
          },
          event: ->(message) { shape(ProgressFrame, message, "frame") }
        )
      end

      # THE SAME ITEMS, DELIVERED RATHER THAN ASKED FOR. A feed is the
      # durable page and the socket wearing one interface: it replays from
      # a position, and — given a realtime client — subscribes and stays in
      # live delivery, so a follower does not choose between recovery and
      # latency.
      #
      # `items:` narrows WHICH broadcasting is subscribed to, not what is
      # filtered after arrival: a follower watching only where a run GOT
      # TO takes `lifecycle` and receives nothing while a round streams.
      # Replay is unaffected — it always serves the full events page — so
      # a narrowed follower still recovers everything through the gap
      # drain when it attaches.
      def feed(position: KernelFeed::Position.start, limit: nil,
               realtime: nil, items: nil, **options)
        KernelFeed.new(
          replay: ->(cursor) { events(after: cursor, limit: limit) },
          subscribe: realtime && realtime_opener(realtime, items: items),
          position: position,
          **options
        )
      end

      # The callable a feed subscribes through, public for the same reason
      # the one-shot half exposes its own: attaching is a decision a
      # console makes when someone looks, not once at construction.
      def realtime_opener(client, items: nil)
        params = {
          workspace_id: @workspace_public_id,
          run_id: @run_public_id,
        }
        params[:items] = items unless items.nil?

        Realtime::FeedSubscription.opener(
          client: client,
          channel: EVENTS_CHANNEL,
          params: params,
          event: ->(message) { shape(ConversationEvent, message, "event") }
        )
      end

      # SAY SOMETHING TO A RUNNING RUN: the one waiting room, hosted by a
      # standalone run. `delivery_mode: "steer"` binds to the run's one
      # turn and lands at its next unambiguous model boundary as the user's
      # trailing message, in queue order with any others; a queued word is
      # the run's follow-up. A run-backed run's door is its
      # conversation's (409 `conversation_hosted` names it).
      def inputs = InputsContext.new(dispatch: @dispatch, path: "#{path}/inputs")

      def start = lifecycle("start")

      # Graceful by default: in-flight work finishes and applies. `force`
      # aborts running model steps now and they re-queue for `resume`.
      def pause(force: false) = lifecycle("pause", force: force)

      def resume = lifecycle("resume")

      # STOP MEANS STOP, so `force` defaults true and terminalizes
      # in-flight work. `force: false` is the graceful drain: running steps
      # and parked awaits finish, nothing new starts, then the run settles.
      def stop(force: true) = lifecycle("stop", force: force)

      # DELETE IS THE TOMBSTONE, never a way to stop a run: a live run
      # refuses 409 `run_busy`, because ending work is `stop`'s
      # decision and this one is about the record. The run leaves every
      # product surface immediately; its rows are reclaimed later.
      def delete
        @dispatch.call(path, method: :delete, success: 204)
        nil
      end

      def tasks_context(task_key)
        RunTasksContext.new(
          dispatch: @dispatch, workspace_public_id: @workspace_public_id,
          run_public_id: @run_public_id, task_key: task_key
        )
      end

      EVENTS_CHANNEL = "AgentAPI::V1::RunEventsChannel".freeze

      private

        def path
          "/agent_api/v1/workspaces/#{@workspace_public_id}" \
            "/runs/#{@run_public_id}"
        end

        def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def transcript_window(before:, limit:, prefix:)
          shape(RunTranscript, @dispatch.call("#{path}/transcript", params: query(before:, limit:, prefix:)))
        end

        # Every lifecycle verb answers the run, so a caller sees the state
        # it just asked for without a second read.
        def lifecycle(verb, **fields)
          shape(Run, @dispatch.call("#{path}/#{verb}", method: :post,
              body: fields.empty? ? nil : fields.transform_keys(&:to_s)), "run")
        end
    end
  end
end
