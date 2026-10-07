require "json"

module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # ONE CLAIMED TASK, from reservation to answer.
    #
    # The order is deliberate at every step and each step is the reason for
    # the next: reserve local capacity, THEN claim (a claim held while
    # queueing burns a deadline nothing can extend); the claim answers with
    # the executable row, so nothing is listed; the handler runs on a worker
    # while the reactor stays free; and the answer carries two axes that the
    # kernel reads differently.
    class TaskRun
      # Left between the handler's cancellation and the park's real deadline,
      # so there is time to SUBMIT. A result computed and never delivered is
      # the same as no result, and the sweep would settle the task
      # `timed_out` — or `uncertain` — while our token went stale. The cap
      # of a long park; a short park keeps a quarter (`headroom`), because a
      # fixed fifteen seconds made every park under it clamp at once.
      SUBMIT_HEADROOM_SECONDS = 15.0

      # A claim we lost is ORDINARY. Another process of this address won,
      # the loop stopped being answerable, a retry re-addressed the row
      # elsewhere, this address lost its eligibility, the row is gone —
      # the 409s a healthy runner meets on the executor plane.
      # None of it is an error and none of it deserves a backoff.
      QUIET_REFUSALS = %w[
        already_claimed task_not_claimable not_addressed_here not_eligible not_found
      ].freeze

      # A COMMIT REFUSED BY TRANSPORT IS RETRIED WHILE THE DEADLINE STANDS:
      # the token makes it safe — a second commit under the
      # same token after the settle is `idle`, not a second answer — and a
      # result computed and never delivered is the same as no result. From
      # a second, doubling, capped; a wait that would cross the park's own
      # deadline is not taken, because the token is stale past it and the
      # sweep has settled the row. With no deadline on the row the retries
      # get a window of their own rather than running forever.
      COMMIT_RETRY_SECONDS = 1.0
      COMMIT_RETRY_CAP_SECONDS = 8.0
      COMMIT_RETRY_WINDOW_SECONDS = 60.0

      # CONDITIONS THAT BELONG TO THE PROCESS, not to a task. Everything
      # else a handler can raise — including a badly-declared
      # `< Exception` from a plugin — fails that task and leaves the
      # runner running, because one extension's mistake must not stop a
      # daemon from claiming work. These three are not mistakes: they are
      # the machine or the operator saying stop.
      FATAL = [SystemExit, SignalException, NoMemoryError].freeze

      # The one answer that is not a `Result`: a handler that could not
      # run, carrying the sentence `outcome: failed` commits.
      Failed = Data.define(:message)

      # THE SERVER'S OWN BOUND, MIRRORED — the runner is a separate gem and
      # cannot read nexus's size registry, so this is a copy and says so.
      # Nexus measures `snapshot_bound` (1 MiB) against the SERIALIZED
      # result entries and refuses over it (`Parks::Settle`) — AFTER the
      # tool has already run. The refusal reaches `answer` as an API error,
      # which logs `runner_submit_refused` and drops the answer: the work
      # is done, paid for, and thrown away, and the task then parks to its
      # deadline. Measuring here is the difference between a truncated
      # answer and no answer.
      #
      # HEADROOM, because the mirror can drift and because the bound is on
      # the JSON, not on the string: escaping can grow a byte into six
      # (\u0000). Truncating slightly early costs a few kilobytes of tail;
      # being wrong the other way costs the entire result.
      SUBMIT_BOUND_BYTES = 1_048_576
      SUBMIT_HEADROOM_BYTES = 64 * 1024

      # Every built-in caps its own TEXT at 50 KiB, so this door is not
      # what bounds them — but not one of them caps `structured_content`
      # (a `find` over a thousand escaped paths is already past a
      # megabyte), and a plugin caps nothing at all. The door is the only
      # place that sees what actually goes on the wire.
      # BYTES ONLY at this door: the tools already decided how many LINES
      # their own output is worth, and re-deciding it here would silently
      # shorten a result that already fits.
      UNBOUNDED_LINES = (2**53) - 1
      TRUNCATION_NOTE = "\n\n[result truncated to fit the server's size bound]".freeze
      STRUCTURED_DROPPED_NOTE =
        "\n\n[structured content omitted: the result exceeded the server's size bound]".freeze

      # THE SERVER'S BOUND ON ONE EXTENSION, MIRRORED (executor.md
      # "Extend"): the kernel's hour when the tool announced no park of its
      # own. Asking for more would meet `extension_too_long`, and one
      # refusal ends the asking.
      EXTENSION_CAP_MS = 60 * 60 * 1000

      # `executor` is the SDK's `ExecutorClient`: the claim, the extension
      # and the commit ride this address's own plane. `toolsets`
      # answers a claimed row's placement (`Toolsets#for`). `sleeper`
      # paces the commit retries and is injected so a test does not wait.
      def initialize(executor:, pool:, toolsets:, log:, clock: nil, hooks: nil, sleeper: nil, on_cancel: nil)
        @executor = executor
        @pool = pool
        @toolsets = toolsets
        @log = log
        @hooks = hooks || Extensions::Hooks::Host.new
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @on_cancel = on_cancel
      end

      attr_writer :hooks

      # Returns :done, :skipped (somebody else's), or :busy.
      #
      # NO GATE BEFORE THE CLAIM: a row addressed here is
      # one this address announced, so `tool_name` on a nudge is carried,
      # never judged; the handler is found by name AFTER the claim, and a
      # name the toolset no longer holds is answered `failed` there.
      #
      # THE TICKET IS ALWAYS RETURNED. Between reserve and the pool taking
      # ownership, anything can raise — an SDK error the claim swallows,
      # but also an ArgumentError on a malformed nudge or an HTTP client
      # raising outright — and a ticket lost on that path was gone for the
      # daemon's life. Enough of them and the runner claimed nothing until
      # a restart, with nothing in its log to say why.
      def call(run_public_id:, task_key:, tool_name: nil) # rubocop:disable Lint/UnusedMethodArgument
        ticket = @pool.reserve
        return :busy if ticket.nil?

        owned = false
        claimed = claim(run_public_id, task_key)
        return :skipped if claimed.nil?

        # THE CLAIM IS THE MARK an operator reads a runner's holdings by:
        # `claimed` on the snapshot moves only after the answer.
        @log.info("runner_task_claimed",
          task: task_key, tool: claimed.task.tool_name, deadline_at: claimed.deadline_at)
        owned = true
        execute(ticket, claimed)
        :done
      ensure
        @pool.release(ticket) if ticket && !owned
      end

      private

        def door(run_public_id, task_key)
          @executor.inbox_task(
            run_public_id: run_public_id, task_key: task_key
          )
        end

        def claim(run_public_id, task_key)
          door(run_public_id, task_key).claim
        rescue CybrosAgent::Api::Error => error
          raise unless quiet?(error)

          nil
        end

        def quiet?(error)
          QUIET_REFUSALS.include?(error.code.to_s)
        end

        # Every invocation is answered under its original claim.
        # `run_handler` takes StandardError,
        # which leaves everything Ruby puts OUTSIDE it — and the pool has
        # already decided what that means: "A handler raising anything at
        # all is that TASK's problem and never the pool's" (pool.rb). It
        # was not the task's problem here. A tool raising, say, a plugin's
        # own `class Boom < Exception` escaped this frame, escaped `take`
        # (which takes only CybrosAgent::Error), escaped `sweep` (only
        # StandardError) and ended `follow` — so the runner stopped
        # claiming ANY work, permanently, while the task it was holding
        # sat claimed-and-unanswerable until its deadline. Nobody is
        # watching a daemon on a home server, which is where that costs
        # the most.
        def execute(ticket, claimed)
          # ONE CLOCK: the deadline is minted on `@clock` and the context
          # reads it on the same one, or a test's clock and the machine's
          # would disagree about whether the park has passed.
          # The extension — for a handler with no clamp of its own — moves
          # that same number, and the commit's window follows it.
          extension = extension_for(claimed)
          context = ExecutionContext.new(
            deadline: handler_deadline(claimed),
            run_public_id: claimed.task.run_public_id,
            conversation_public_id: claimed.task.conversation_public_id,
            workspace_public_id: claimed.task.workspace_public_id,
            task_key: claimed.task.task_key, clock: @clock, extension: extension,
            scope: claimed.task.scope, claim_token: claimed.claim_token, progress: progress_for(claimed),
            claim_poller: claim_poller_for(claimed), on_cancel: @on_cancel,
            orchestration: orchestration_for(claimed),
            attachments: ClaimAttachments.new(
              task: door(claimed.task.run_public_id, claimed.task.task_key), claim_token: claimed.claim_token
            )
          )
          fatal = nil
          result =
            begin
              run_handler(ticket, context, claimed, started_at: @clock.call)
            rescue Exception => error # rubocop:disable Lint/RescueException
              fatal = error if FATAL.any? { |kind| error in ^kind }
              failure(claimed, "The tool could not run: #{error.class}: #{error.message}")
            end
          claimed = claimed.with(deadline_at: extension.deadline_at) if extension
          submit(claimed, result)
          # ANSWERED FIRST, THEN RE-RAISED. A shutdown or an exhausted
          # machine still ends the runner — swallowing those into a task
          # failure would be a lie about why the work stopped — but it
          # ends with the claim released rather than held.
          raise fatal if fatal
        end

        # THE TWO AXES, decided in exactly one place.
        #
        # A handler that RETURNED — even a Result carrying is_error — ran,
        # and the model reads its answer and self-corrects. A handler that
        # RAISED could not run at all, and only that becomes
        # `outcome: "failed"`, which takes the task's own failure policy.
        # Nothing else in this file may set `failed`.
        # THREE INTERRUPTIONS, TWO ANSWERS: the DEADLINE
        # is the tool running too long, which is data — `completed,
        # is_error` "timed out", with cancellation requested; the
        # kernel's CANCEL and the runner's SHUTDOWN are `failed`
        # interrupted (the cancel's commit meets a row already `canceled`
        # and is idle; a draining runner is not a timeout). A malformed
        # input is data too, refused before the handler runs.
        # THE TICKET LEAVES WITH THE POOL OR WITH THIS FRAME. `Pool#run`
        # releases it on every path once handed the job; a path that never
        # reaches the pool releases it here, or the runner is one worker
        # smaller for the daemon's life.
        def run_handler(ticket, context, claimed, started_at:)
          name = claimed.task.tool_name
          handed = false

          # THE GATE RUNS ON THE WORKER. THE PLACEMENT IS
          # RESOLVED THERE TOO: the row's
          # conversation names its environment, the host's resolver may
          # read the store to answer it, and the context is placed ONCE —
          # env, record and the host's ports resolver (the editor's port is looked up per call by the record's anchor) — before
          # the `tool_call` chain, whose hooks read the conversation's
          # root off it; the tool is the PLACEMENT's instance. The chain and the schema check run INSIDE the pool
          # block: a hook may block — the checkpoint capture is thirty
          # seconds of `git add` — and `pool.rb`'s rule holds for hooks as
          # for handlers: the reactor runs neither, or every in-flight
          # claim, submit, progress flush and deadline renewal stalls
          # behind one call. A veto now costs a ticket for the microseconds
          # of a regex, and `ExecutionContext.current` is bound where the
          # chain runs, so a hook reads the loop off it. A refusal is DATA
          # — `Result.error` submits as `completed, is_error: true`, so the
          # model reads why and corrects itself, where failing the task
          # would take the round's failure policy and tell it nothing — and
          # it is answered WITHOUT the `tool_result` chain: nothing ran.
          handed = true
          refused = nil
          tool = nil
          hooks = nil
          owners = []
          # The pool may time out while a non-cooperative worker continues.
          # Keep the one set of leases until BOTH the actual handler and this
          # caller's result hooks finish; either side may be the last to leave.
          finishes = 2
          resource_lock = Mutex.new
          finish_resources = lambda do
            last = resource_lock.synchronize do
              finishes -= 1
              finishes.zero?
            end
            owners.reverse_each(&:release) if last
          end
          value = @pool.run(ticket, context) do
            placement = @toolsets.for(claimed.task)
            hooks = @hooks
            context.place(tool_env: placement.env, binding: placement.binding, ports: @toolsets.ports)
            begin
              tool = placement.toolset.fetch(name)
            rescue KeyError
              # Only lookup failure is announcement drift. A handler's
              # missing input must retain its own error and diagnosis.
              next failure(claimed, "The tool could not run: this runner no longer serves #{name.inspect}")
            end
            ([tool.owner] + hooks.owners).compact.uniq.each do |owner|
              owner.acquire
              owners << owner
            end
            gated = admit(name, tool, arguments(claimed.task), hooks: hooks)
            case gated
            in Result
              refused = gated
            else
              tool.handler.call(gated, context)
            end
          ensure
            finish_resources.call
          end
          return refused if refused

          result = case value
          in Failed then return value
          in Result then value
          else Result.ok(value.to_s)
          end
          # FAIL-OPEN: the tool already ran, and losing a real answer
          # because a formatter raised would turn an observer into a
          # destroyer. THE CONTEXT IS BOUND HERE TOO: this chain runs on
          # the reactor (the pool binds the context on its worker alone),
          # and a `tool_result` hook reads the loop off `ExecutionContext.
          # current` exactly as the `tool_call` chain does — the checkpoint
          # key rides the first write-kind result BY that loop id, so an
          # unbound context here would leave every key on the floor.
          ExecutionContext.with(context) { hooks.after_result(name, result, tool) }
        rescue ExecutionContext::Cancelled => error
          if error.reason == :deadline
            return timed_out(claimed, started_at)
          end

          failure(claimed, "The tool was interrupted: #{error.message}")
        rescue Pool::Stopped => error
          failure(claimed, "The tool was interrupted: #{error.message}")
        rescue StandardError => error
          failure(claimed, "The tool could not run: #{error.class}: #{error.message}")
        ensure
          finish_resources&.call
          @pool.release(ticket) unless handed
        end

        # FAIL-CLOSED: the chain, then the schema. Answers the arguments
        # the handler receives, or the refusal `Result`. WHAT THE TOOL
        # RECEIVES is what is validated — after the rewrite, against the
        # schema the tool itself declared.
        def admit(name, tool, arguments, hooks: @hooks)
          case hooks.before_call(name, arguments, tool)
          in Extensions::Hooks::Veto(extension:, reason:)
            Result.error("blocked by #{extension}: #{reason}")
          in gated
            refusal = InputSchema.refusal(tool.validator, gated)
            refusal ? Result.error("invalid_tool_arguments: #{refusal}") : gated
          end
        end

        def failure(claimed, message)
          @log.warn("runner_tool_failed",
            task: claimed.task.task_key, tool: claimed.task.tool_name, detail: message)
          Failed.new(message: message)
        end

        # A timeout reports the delivery failure, not an assertion that an
        # arbitrary tool's external effects were undone. A non-cooperative
        # handler may still be finishing on its owned worker.
        def timed_out(claimed, started_at)
          elapsed = @clock.call - started_at
          @log.warn("runner_tool_timed_out",
            task: claimed.task.task_key, tool: claimed.task.tool_name, elapsed_seconds: elapsed.round(1))
          Result.error(
            "The tool timed out: its granted execution deadline passed before it returned a result. " \
            "Cancellation was requested; external effects may be incomplete. " \
            "Check its effect before calling it again."
          )
        end

        # The row carries its input as an object, empty when the call named
        # none (`tool_input: :json_object_or_empty` on the SDK projection).
        def arguments(task) = task.tool_input

        # The code a refusal is logged under: the kernel's for a typed
        # refusal, the class name for a transport's or the machine's.
        def error_code(error)
          case error
          in CybrosAgent::Api::Error then error.code
          else error.class.name
          end
        end

        # STORABLE FIRST, THEN BOUNDED: every string of the answer
        # passes `StorableText` before the bound is measured, because the
        # NUL escape grows a byte into six and the bound is on the
        # submitted bytes.
        def submit(claimed, result)
          case result
          in Failed(message:)
            answer(claimed, outcome: "failed", content: bounded_text(StorableText.text(message)))
          in Result
            content, structured, structured_present = bounded(storable(result))
            # THE CARRIER RIDES AS THE TOOL LEFT IT: `metadata` is the runner's
            # own record (the reserved `checkpoint` key), never bounded here —
            # a key is a hash and a store id, bytes the envelope bound never
            # reaches — and absent from the commit when the result carries
            # none.
            content, missing = with_captures(claimed, content, result.files)
            if result.files_required && missing
              content = "File publication failed; no downloadable artifact was produced."
            end
            answer(claimed, outcome: "completed", content: content,
              structured_content: structured, structured_content_present: structured_present,
              is_error: result.is_error || (result.files_required && missing), title: result.title, metadata: result.metadata)
          end
        end

        # THE ONE UPLOAD SITE. A tool names the files it
        # wants a client to fetch (`Result#files`); this is where they leave
        # the machine — AFTER the handler returned, on this address's own
        # plane (`executor.uploads`), each linked as a `resource_link` block
        # beside the text. Tools stay transport-blind and the gem keeps its
        # "loads with no daemon" rule. `content` stays a String when there is
        # nothing to link, so every result that names no file commits the
        # bytes it always did.
        #
        # A CAPTURE THAT WILL NOT STAGE COSTS THE LINK, NEVER THE ANSWER: a
        # refusal at the upload door (the byte bound's `413`, a transport
        # that dropped, a file that vanished between the handler and here)
        # is logged once and that link is left out — the text half, which
        # already names the path on this runner, commits as it stands.
        def with_captures(claimed, content, files)
          links = files.filter_map { |path| capture(claimed, path) }
          missing = links.length != files.length
          return [content, missing] if links.empty?

          [content_blocks(content) + links, missing]
        end

        def capture(claimed, path)
          upload = @executor.uploads.create(path)
          CybrosAgent::Api::ResourceLink.to_upload(upload.public_id, name: File.basename(path),
            mime_type: upload.content_type, size: upload.byte_size).to_h
        rescue CybrosAgent::Api::Error, CybrosAgent::TransportError, SystemCallError, IOError => error
          @log.warn("runner_capture_refused",
            task: claimed.task.task_key, tool: claimed.task.tool_name, path: path, code: error_code(error))
          nil
        end

        def storable(result)
          content = case result.content
          in String => text then StorableText.text(text)
          in Array => blocks then StorableText.value(blocks)
          end
          result.with(content: content,
            structured_content: StorableText.value(result.structured_content))
        end

        # THE TEXT WINS. `content` is what the MODEL reads and self-corrects
        # on; `structured_content` is result data for the client (the MCP
        # division `Result` records). When only one can fit, keeping the
        # model's half is the choice that leaves the round able to continue
        # — and the drop is stated in the text rather than being silent,
        # because a client reading typed data that is simply absent has no
        # way to tell that from a tool that returned none.
        def bounded(result)
          structured = result.structured_content
          content = result.content
          present = result.structured_content_present
          return [content, structured, present] if fits?(content, structured, present: present)

          without = if present
            case content
            in String => text then "#{text}#{STRUCTURED_DROPPED_NOTE}"
            in Array => blocks then [*blocks, { "type" => "text", "text" => STRUCTURED_DROPPED_NOTE }]
            end
          else
            content
          end
          return [without, nil, false] if fits?(without, nil)

          text = content_blocks(without).filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
          [bounded_text(text), nil, false]
        end

        def bounded_text(text)
          text = text.to_s
          return text if text.bytesize <= room

          kept = room - TRUNCATION_NOTE.bytesize
          # The TAIL is what a command's error message is in, and the tail
          # is what every tool here already keeps when it truncates.
          "#{Truncation.truncate_tail(text, max_lines: UNBOUNDED_LINES, max_bytes: kept).content}" \
            "#{TRUNCATION_NOTE}"
        end

        # Measured on the SERIALIZED shape, because that is what the server
        # measures. Serializing a megabyte to check it is cheap next to
        # having run the tool that produced it.
        def content_blocks(content)
          case content
          in String => text then [{ "type" => "text", "text" => text }]
          in Array => blocks then blocks
          end
        end

        def fits?(text, structured, present: !structured.nil?)
          payload = { "content" => text }
          payload["structured_content"] = structured if present
          JSON.generate(payload).bytesize <= room
        rescue StandardError
          # Unserializable structured content is the caller's bug, not a
          # reason to hold the claim: report it as not fitting and let the
          # text go alone.
          false
        end

        def room = SUBMIT_BOUND_BYTES - SUBMIT_HEADROOM_BYTES

        # `structured_content` USED TO RIDE THE UI CHANNEL because our wire
        # had no field for it. It has one now — the CLIENT's channel, served
        # whole on the task read and never rendered to the model (the three
        # channels, `Result`); `content` is the model's, and `metadata` the
        # carrier the UI reads.
        def answer(claimed, outcome:, content:, structured_content: nil,
                   is_error: nil, title: nil, metadata: nil, structured_content_present: !structured_content.nil?)
          fields = { claim_token: claimed.claim_token, outcome: outcome, content: content }
          fields[:structured_content] = structured_content if structured_content_present
          fields[:is_error] = is_error unless is_error.nil?
          fields[:title] = title unless title.nil?
          fields[:metadata] = metadata unless metadata.nil?

          commit(claimed, fields)
        rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
          # A TYPED REFUSAL IS FINAL: past the deadline the token is stale
          # and the sweep has settled the task; a payload the door refuses
          # meets the same door again. Saying so once is the whole response.
          # (`idle` is a 200 and never lands here — the settle already
          # holds this answer.) A transport refusal lands here only after
          # the retries ran out of deadline.
          @log.warn("runner_submit_refused",
            task: claimed.task.task_key, code: error.code)
          nil
        end

        # The transport half of the retry rule: a refusal the KERNEL never
        # saw — the connection dropped, a throttle — is tried again while
        # a wait still fits before the deadline. A throttle's own
        # `retry_after` is honoured when it is the longer wait.
        def commit(claimed, fields)
          door = door(claimed.task.run_public_id, claimed.task.task_key)
          until_at = commit_deadline(claimed)
          delay = COMMIT_RETRY_SECONDS
          begin
            door.commit(**fields)
          rescue CybrosAgent::TransportError, CybrosAgent::Api::RateLimited => error
            wait = [delay, error.retry_after.to_f].max
            raise if @clock.call + wait >= until_at

            @sleeper.call(wait)
            delay = [delay * 2, COMMIT_RETRY_CAP_SECONDS].min
            retry
          end
        end

        # The handler is stopped EARLY, leaving room to deliver. Absent a
        # deadline the task has no clock at all and the handler runs until
        # it finishes or the runner drains.
        def handler_deadline(claimed) = handler_deadline_at(claimed.deadline_at)

        def handler_deadline_at(deadline_at)
          remaining = remaining_seconds_at(deadline_at)
          return nil if remaining.nil?

          @clock.call + [remaining - headroom(remaining), 0.0].max
        end

        # THE ASK FOR MORE TIME (executor.md "Extend"), armed for a handler
        # with no clamp of its own on a row with a clock: at half the park,
        # and again at each half, the claimant asks the kernel for the park
        # again — the tool's own announced park when it declared one, the
        # row's own under the kernel's hour otherwise — and the pool's wait
        # moves the one deadline by the answer. A tool that clamps itself
        # (bash) never asks; a name the toolset no longer holds is answered
        # `failed` downstream.
        # READ OFF PLACEMENT ZERO, on the reactor: the park and the clamp are
        # the tool CLASS's, identical on every placement.
        def extension_for(claimed)
          tool = @toolsets.zero.toolset.fetch(claimed.task.tool_name)
          park = remaining_seconds(claimed)
          return nil if tool.internal_clamp || park.nil? || !park.positive?

          DeadlineExtension.new(park_seconds: park, deadline_at: claimed.deadline_at, clock: @clock) do
            request_extension(claimed, tool)
          end
        rescue KeyError
          nil
        end

        # ONE REFUSAL ENDS THE ASKING — a typed refusal (`not_claimant` after
        # a cancel, `extension_too_long`, a stopped loop) or a transport the
        # door could not cross: the deadline the kernel would not move is
        # the deadline, logged once. Answers the new handler deadline and
        # the kernel's new `deadline_at` and remaining granted park, or nil. A credential-owner failure
        # is the same refusal: it must not escape the pool's wait and answer
        # for a handler that is still running.
        def request_extension(claimed, tool)
          # THE PARK AGAIN, EXACTLY: the tool's own announced park when it
          # announced one — the kernel's bound — else the budget the row
          # states under the kernel's hour. Never the park as measured here:
          # the ask on the wire, and the `timeout_ms` the kernel narrates,
          # read no clock of this runner's.
          timeout_ms = [tool.timeout_ms || claimed.task.timeout_ms, EXTENSION_CAP_MS].min
          extended = door(claimed.task.run_public_id, claimed.task.task_key)
            .extend(claim_token: claimed.claim_token, timeout_ms: timeout_ms)
          @log.info("runner_task_extended",
            task: claimed.task.task_key, tool: claimed.task.tool_name,
            deadline_at: extended.deadline_at, timeout_ms: timeout_ms)
          [handler_deadline_at(extended.deadline_at), extended.deadline_at, remaining_seconds_at(extended.deadline_at)]
        rescue CybrosAgent::Error => error
          @log.warn("runner_extension_refused", task: claimed.task.task_key, code: error_code(error))
          nil
        end

        # THE FRAMES A RUNNING TOOL POSTS (executor.md "Progress"), keyed
        # by this claim: the handler hands in a tail, the pool's wait posts
        # it here at the kernel's cadence. `202` whether the kernel
        # broadcast or dropped it; a refusal — the claim ended under it
        # (`not_claimant` after a cancel), a stopped loop, a transport the
        # door could not cross — is logged once and ends the posting for
        # this run, as one refusal ends the extension's asking. This includes
        # failures reading or renewing the request's credential; the handler
        # and its resources remain owned until the actual execution ends.
        def progress_for(claimed)
          Progress.new(clock: @clock, post: ->(text) { post_progress(claimed, text) })
        end

        def orchestration_for(claimed)
          ClaimOrchestration.new(task: door(claimed.task.run_public_id, claimed.task.task_key),
            claim_token: claimed.claim_token, log: @log)
        end

        def claim_poller_for(claimed)
          ClaimStatusPoller.new(task: door(claimed.task.run_public_id, claimed.task.task_key),
            claim_token: claimed.claim_token, worker_count: @pool.worker_count, clock: @clock, log: @log)
        end

        def post_progress(claimed, text)
          @executor.report_progress(
            "run_public_id" => claimed.task.run_public_id, "task_key" => claimed.task.task_key,
            "claim_token" => claimed.claim_token, "text_tail" => text
          )
          true
        rescue CybrosAgent::Error => error
          @log.warn("runner_progress_refused", task: claimed.task.task_key, code: error_code(error))
          false
        end

        # Fifteen seconds of a long park, a quarter of a short one: a 30 s
        # announced park leaves its handler 22.5 s, a 10 s park 7.5 s.
        def headroom(remaining) = [SUBMIT_HEADROOM_SECONDS, remaining / 4.0].min

        # The commit's clock is the park's own: past it the token is dead.
        def commit_deadline(claimed)
          remaining = remaining_seconds(claimed) || COMMIT_RETRY_WINDOW_SECONDS
          @clock.call + [remaining, 0.0].max
        end

        def remaining_seconds(claimed) = remaining_seconds_at(claimed.deadline_at)

        def remaining_seconds_at(at)
          return nil if at.nil?

          Time.parse(at).to_f - Time.now.to_f
        rescue ArgumentError, TypeError
          nil
        end
    end
  end
end
