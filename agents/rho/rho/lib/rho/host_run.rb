require "monitor"
# The socket half of the SDK, required beside the file that uses it: rho is
# the consumer that asked for realtime.
require "cybros_agent/realtime"
require_relative "host_run/streams"
require_relative "host_run/events"
require_relative "host_run/recovery"

module Rho
  # One HOST this daemon follows over its one feed: a
  # standalone loop's own feed, or a conversation's. The useful state is a
  # table keyed by task (the only name the event vocabulary uses), the
  # current round's text preview, where the TURN stands, and whether the
  # loop behind it is waiting on a human. A fiber on the reactor, read
  # under one monitor.
  #
  # THE STATE IS THE CURRENT TURN'S. A conversation host runs many turns,
  # each backed by its own loop. A new turn or regenerated candidate
  # starts the table over, while `loops` keeps every backing loop the daemon
  # followed — which is how a verb given an earlier loop id still finds
  # its host's row.
  class HostRun
    include Streams
    include Events
    include Recovery

    # The kernel's own `origin` words on an `input_accepted` item — the
    # rows that are mail to the conversation (a task's receipt, a child's
    # reply); `person` and `agent` are principals' words. EVERY WRAPPED
    # ROW is what a watcher is told about with its speaker:
    # the kernel's two, and a peer's `agent` row — a `person` row is bare.
    KERNEL_ORIGINS = %w[task_result child].freeze
    WRAPPED_ORIGINS = (KERNEL_ORIGINS + %w[agent]).freeze

    # The REST cadence, including recovery of a missed wake on an open socket.
    POLL_SECONDS = 1.0

    # Completed conversations keep following, but need no per-second reads.
    IDLE_POLL_SECONDS = 60.0

    # The narrowing a host subscribes to while nobody is watching: where
    # its turn GOT TO, plus the ask. A daemon may hold many and read none.
    LIFECYCLE_ITEMS = "lifecycle".freeze

    # THE FRAMES KEPT FOR A POLLING READER (`rho watch`): a
    # bounded ring of the newest progress frames, each under a sequence a
    # poller reads past; a frame is droppable by construction, and one a
    # slow poll misses is exactly that.
    FRAMES_KEPT = 64

    # THE MEMORY CEILING ON A PREVIEW, and only that: what is held is a
    # TAIL of a longer answer, the durable transcript is a paginated read,
    # and the accumulator counts every byte it ever took so a settle past
    # the ceiling still reads as a continuation. What ENDS an answer is a
    # key switch (a new round's task key, a new reply's variant) or a
    # `stream_reset`, never a round ending: a round-end clear raced the
    # settle and reprinted the whole reply under it.
    TEXT_BOUND = 64 * 1024

    # The roots the kernel's flat tools mint under a call key —
    # `<call>-model-1`, `<call>-ask-1`, `<call>-spawn-1` — the twin of
    # `AgentLoops::TaskResultEnvelope::FLAT_ROOT` (nexus, task_result_envelope.rb),
    # spelled here because the SDK exports no key grammar. A branch task's
    # `after` chain reaches one; a spine task's never does.
    BRANCH_ROOT = /\A(?<call>r\d+t\d+)-(?:model|ask|spawn)-1\z/

    # Derived from the gem's own vocabulary, never a list written here: a
    # second copy went blind the day `running` split into who-is-waited-on.
    # `after` is the authored list the task hangs from, on
    # every status item; a root's is empty. `on_failure` rides every item
    # (an `absorb` failure stamps no resolution, so the policy is what says
    # it is settled); `extension_ms` is the claimant's latest ask for more
    # time (`task_deadline_extended`), dropped when the status next moves;
    # `resolved_by` is who settled a park (`{kind, public_id}`, the settle's narration), on the item that settled it.
    # THE ROUND'S FACTS ride a model task from its `round_result` — `model`
    # (the trio that answered, `provider/model`), `finish_quality` (a caveat,
    # or `refused`/`blocked` when a provider declined the step) and
    # `refusal_category` (the provider's word, absent when it named none) —
    # and are dropped when the task next moves. `model_change` is the
    # switch the kernel narrated on the task's own item — `{from, to,
    # reason, category?}`, the step re-run on another model — kept through
    # the round that follows it and dropped on the next move.
    Task = Data.define(:task_key, :kind, :status, :error_key, :failure_resolution, :after,
                       :on_failure, :extension_ms, :resolved_by, :model, :finish_quality, :refusal_category,
                       :model_change) do
      def initialize(after: [], on_failure: nil, extension_ms: nil, resolved_by: nil, model: nil, finish_quality: nil,
                     refusal_category: nil, model_change: nil, **rest) = super

      def terminal? = CybrosAgent::Api::TASK_TERMINAL_STATUSES.include?(status)
      def live? = !terminal?
      def started? = live? && !CybrosAgent::Api::TASK_PRE_START_STATUSES.include?(status)

      def to_h
        { task_key: task_key, kind: kind, status: status, on_failure: on_failure,
          error_key: error_key, failure_resolution: failure_resolution,
          after: (after unless after.empty?), extension_ms: extension_ms, resolved_by: resolved_by,
          model: model, finish_quality: finish_quality, refusal_category: refusal_category,
          model_change: model_change }.compact
      end
    end

    # WHAT A LISTENER IS HANDED for an item that did not come off the
    # events feed: `type` and `payload`, the two members the daemon's SSE
    # relay reads (`loop_routes.rb`'s `stream.deliver`). The transcript
    # pump fans the kernel's own delta vocabulary and nothing new — a
    # settle is translated into the frames a printer already understands.
    Frame = Data.define(:type, :payload)

    # `attention` is nil unless the loop is asking. When set it carries the
    # reason and the tasks an adjudicator can act on — the actionable half
    # of a hold, which `status` alone does not express.
    Attention = Data.define(:reason, :blocked_task_keys) do
      def to_h = { reason: reason, blocked_task_keys: blocked_task_keys }
    end

    # `status` is the TURN's (`pending`, `running`, `failed`, `completed`, `canceled`), `loop_status` the loop row's own word, and
    # `loop`/`turn` the CURRENT turn's correlation ids; `loops` is every
    # backing loop this follower has seen. `complete` is a LEVEL, never a
    # latch: a hold renders `failed` and a retry renders `running` again.
    # `mailed` is every background answer the kernel mailed to this
    # conversation after its turn's reply was final, by the key
    # the model saw — read off `input_accepted{origin: task_result}`.
    # `runner` is the binding as the feed last said it (`runner_bound`) — nil until a handoff is followed, and after a reap.
    # `turn_kind` is the current turn's kind as the
    # kernel's `turn_status` on a conversation host carries it —
    # `direct_reply`, `compaction_summary`, … — so a wait for the loop a
    # person's word minted can read past the between-turn summary's; nil
    # on a loop host and until an item names it, so a snapshot without it
    # is byte-identical to what this daemon always served.
    # `text_length` is every byte accumulated since the last reset, beside
    # the bounded `text`: a POLLING reader (`rho watch`) needs it to tell a
    # continuation from a replacement on a reply longer than the bound, and
    # it is absent when nothing streamed, so a snapshot with no text is
    # byte-identical to what this daemon always served. `reasoning` is the
    # second channel, held under the same bound and printed only when asked.
    # `frames` is the newest progress frames off the host's
    # `progress` feed — `{seq, type, task_key | process_id, …}`, the
    # kernel's frame under a daemon sequence — absent when none arrived,
    # so a snapshot with no frames is byte-identical to what this daemon
    # always served. `blocked` is the last input the kernel REFUSED at materialization
    # (`input_blocked` with a durable reason — an unknown model, a refused
    # selection), by id, so the author can tell a blocked input from a slow
    # kernel; absent when none was. `children` is the
    # conversation's child listing as last read — each spawned
    # conversation with its label, its answerer and whether a reply runs
    # there — absent on a standalone loop.
    Snapshot = Data.define(:public_id, :host_type, :status, :loop_status, :failure_reason,
                           :failure_reason_key, :loop, :turn, :turn_kind, :loops, :attention, :tasks, :text,
                           :text_length, :reasoning, :sequence, :complete, :live, :until, :mailed, :runner,
                           :blocked, :children, :frames) do
      def initialize(runner: nil, turn_kind: nil, text_length: nil, reasoning: nil, blocked: nil, children: nil,
                     frames: nil, **members) =
        super(runner: runner, turn_kind: turn_kind, text_length: text_length, reasoning: reasoning, blocked: blocked,
          children: children, frames: frames, **members)

      def to_h
        {
          public_id: public_id, host_type: host_type, status: status, loop_status: loop_status,
          failure_reason: failure_reason, failure_reason_key: failure_reason_key,
          loop: self.loop, turn: turn, turn_kind: turn_kind, loops: loops, attention: attention&.to_h,
          tasks: tasks.map(&:to_h),
          text: text, text_length: text_length, reasoning: reasoning,
          sequence: sequence, complete: complete, live: live, until: self.until,
          mailed: mailed, runner: runner, blocked: blocked, children: children, frames: frames,
        }.compact
      end
    end

    # The turn-shaped terminal set, from the gem: what `turn_status` carries
    # on both hosts. A turn-shaped `failed` is a level a retry or an answer
    # reopens; only the LOOP's own terminal says nothing further will come.
    TURN_TERMINAL_STATUSES = CybrosAgent::Api::TURN_TERMINAL_STATUSES
    LOOP_TERMINAL_STATUSES = CybrosAgent::Api::LOOP_TERMINAL_STATUSES

    # Task-grained, like everything the control surface serves: keys and
    # statuses, never the engine's graph — one shape for every loop row.
    def self.loop_projection(loop_row)
      {
        public_id: loop_row.public_id,
        status: loop_row.status,
        deliverable_task_key: loop_row.deliverable_task_key,
        tasks: loop_row.tasks.map do |task|
          { key: task.key, kind: task.kind, status: task.status,
            tool_name: task.tool_name }.compact
        end,
      }
    end

    attr_reader :host, :realtime, :context

    def event_position = @feed.position

    # `context` is the host's own SDK context — the loop's or the conversation's, both
    # answering `feed` and `realtime_opener`. `gate` is an --until policy's gate, bound to
    # one backing loop, and `spawner` runs its checks on the host's reactor; `loop_context`
    # builds the LOOP's context the gate reads and appends through (a loop host is its own).
    # `on_complete` is told at every turn terminal; `on_turn` whenever the turn/loop pair
    # the feed names moves, so the store row follows it; `on_runner_bound` with the payload
    # whenever a handoff lands on the host feed, so a binding a Human moved through the SDK
    # re-renders the next turn. `on_attention` receives the attention and its originating
    # loop, even for background work; only the current execution changes the snapshot. It
    # fires outside the monitor so the side's auto-deny can use HTTP. `on_ended` is told
    # once when the host is archived or no longer readable. An archive item is
    # reconciled with the current row because a restored host replays that history;
    # a tombstone item or a refused read ends the follow. The daemon forgets the host and
    # releases what its loops started. `loop`/`turn` seed a re-adopted follower with what
    # the row already knew. `stream` is the HOST knob: with it false this follower never
    # opens the host's transcript feed at all — no second logical subscription, no deltas,
    # the once-per-change lines alone. It is the same axis as the events feed's own
    # narrowing, decided by whoever opened the host (`rho do --no-stream`), never by whoever
    # watches. `on_children` is told, with the run, the child ids NEW to the listing on the
    # two edges that read it — the settle, a child's mail — never one already listed, never
    # an empty set: the daemon writes each new child's environment copy from it.
    def initialize(host:, context:, realtime: nil, live: true, logger: nil,
                   sleeper: ->(seconds) { sleep(seconds) }, gate: nil, spawner: nil,
                   on_complete: nil, on_turn: nil, on_runner_bound: nil, on_attention: nil, on_ended: nil,
                   on_children: nil, loop_context: nil, loop: nil, turn: nil, stream: true)
      @host = host
      @context = context
      @logger = logger
      @realtime = realtime
      @live = live && !realtime.nil?
      @gate = gate
      @spawner = spawner
      @on_complete = on_complete
      @on_turn = on_turn
      @on_runner_bound = on_runner_bound
      @on_attention = on_attention
      @on_ended = on_ended
      @on_children = on_children
      @runner = nil
      @loop_context = loop_context
      @restored_sequence = nil
      @feed = @context.feed(realtime: realtime, items: (@live ? nil : LIFECYCLE_ITEMS),
        after_replay: method(:recover_replay))
      @sleeper = sleeper
      @monitor = Monitor.new
      @tasks = {}
      @stream = stream
      @transcript = nil
      # THE THIRD PUMP: the host's `progress` feed — what an
      # executor is doing right now — a subscription held like the
      # transcript's, and the ring a poller reads.
      @progress = nil
      @frames = []
      @frame_sequence = 0
      # The five laws of that feed live in the gem, not here: one object,
      # shared with every other client of it ("refuses a rho-local second feed").
      @text = CybrosAgent::Api::TranscriptAccumulator.new(bound: TEXT_BOUND)
      @reasoning = CybrosAgent::Api::TranscriptAccumulator.new(bound: TEXT_BOUND)
      @status = "pending"
      @loop_status = nil
      @failure_reason = nil
      @failure_reason_key = nil
      @loop = loop || host.own_loop
      @turn = turn
      @variant = nil
      @turn_kind = nil
      @turn_visibility = "visible"
      @turn_concealed = false
      @last_deleted_turn = nil
      @loops = [@loop].compact
      # EMPTY, never seeded with the row's turn: `turns_seen` are the turns
      # whose EVENTS moved this table, and a re-adopted follower replays the
      # feed from the start — the row's turn is the last one the replay
      # reaches, and a seed would reject its own events as a turn left
      # behind (the table ended one turn short after every restart).
      @turns_seen = []
      # Turns with a final body from the transcript tail or HTTP recovery,
      # marked just before its last delivery frame. Events alone cannot seal text.
      @transcript_settled = []
      @transcript_settling = nil
      @attention = nil
      @complete = false
      @stopped = false
      @mailed = []
      @blocked = nil
      # The child listing, read on the two edges that can
      # change it; nil on a host with no children door (a standalone loop).
      @children = (host.outlives_turn? ? [] : nil)
      # A page or terminal following along wants the same events as they
      # land, rather than polling the snapshot.
      @listeners = {}
      @listener_sequence = 0
    end

    def public_id = @host.public_id

    def host? = true

    def one_shot? = false

    # Whether an id names this host's work: the host's own id, or any loop
    # the follower saw back a turn — the current one or an earlier one
    # (`loops`). The one rule the Ops listing marks a server loop
    # `followed` by and the daemon's follower lookup resolves a loop id by.
    def backs?(public_id)
      @monitor.synchronize { @host.public_id == public_id || @loops.include?(public_id) }
    end

    # A listed child inherits this host's workspace, without becoming a
    # host this daemon follows. Replaying the parent feed restores the list.
    def child?(public_id)
      @monitor.synchronize { @children&.any? { |child| child.fetch(:public_id) == public_id } || false }
    end

    # Followed on the host's reactor, then the gate asked to look once: a
    # settle may have happened while nobody followed.
    def start(spawner)
      spawner.call { follow }
      # Events carry lifecycle; transcript and progress carry previews.
      # Each is a separate subscription on the same multiplexed client.
      spawner.call { follow_transcript }
      spawner.call { follow_progress }
      spawner.call { follow_recovery } unless @realtime.nil?
      nudge
      self
    end

    # One pass is a full barrier with no socket (the sleep is the latency);
    # with one it stays live until the host's terminal, and a feed that spent
    # its transient budget on a down kernel is resurrected by the next pass.
    # A conversation has no terminal of its own: the follow runs until the
    # daemon stops it, forgets the host, or the kernel says it ENDED.
    def follow
      until stopped_or_settled?
        begin
          @feed.each { |event| apply(event) }
        rescue *CybrosAgent::KernelFeed::TRANSIENT_ERRORS => error
          @sleeper.call(error.retry_after || POLL_SECONDS)
          next
        end
        break if stopped_or_settled?

        @sleeper.call(POLL_SECONDS)
      end
      self
    rescue CybrosAgent::Api::NotFound, CybrosAgent::Api::Forbidden => error
      @logger&.warn("host.follow_failed", host: public_id, host_type: @host.type,
                    error_class: error.class.name,
                    error: CybrosAgent::Redaction.call(error.message))
      end_host
      raise
    rescue StandardError => error
      # Fire-and-forget: without this line a dead follower is a round that
      # looks like it is still working.
      @logger&.warn("host.follow_failed", host: public_id, host_type: @host.type,
                    error_class: error.class.name,
                    error: CybrosAgent::Redaction.call(error.message))
      raise
    end

    # A quiet, healthy socket cannot expose a missing final wake as a gap.
    # Probe one durable item; only the feed consumes it and owns its cursor.
    # Rebinding wakes that same consumer through the SDK's replay barrier.
    def follow_recovery
      until stopped_or_settled?
        begin
          page = @context.events(after: @feed.position.cursor, limit: 1)
          break if stopped_or_settled?

          # The live consumer may have caught up while this read was in flight.
          # The allocated head also detects items that expired before this
          # probe. Only the feed's bounded replay can restore that missing state.
          missing = @monitor.synchronize { page.watermark > replayed_sequence }
          @feed.rebind if missing || page.items.any? { |event| event.sequence > @feed.position.sequence }
          recover_transcript
        rescue *CybrosAgent::KernelFeed::TRANSIENT_ERRORS => error
          @sleeper.call(error.retry_after || recovery_interval) unless stopped_or_settled?
          next
        end
        break if stopped_or_settled?

        @sleeper.call(recovery_interval)
      end
      self
    rescue CybrosAgent::Api::NotFound, CybrosAgent::Api::Forbidden
      end_host
      self
    rescue StandardError => error
      @logger&.warn("host.recovery_failed", host: public_id, host_type: @host.type,
                    error_class: error.class.name,
                    error: CybrosAgent::Redaction.call(error.message))
      raise
    end

    # Attaching re-enters the SDK's barrier (drain, subscribe, drain the gap,
    # go live), so a lifecycle-only follower hands over everything that
    # landed. Both answer whether they changed anything.
    def attach_socket
      return false if @realtime.nil? || @monitor.synchronize { @live || @stopped }

      @feed.detach
      return false unless @feed.attach(@context.realtime_opener(@realtime))
      @monitor.synchronize { @live = true }
      true
    end

    # Narrowing the events feed and ENDING the transcript one: nobody is
    # watching, and a logical subscription nobody reads is a buffer the
    # server fills until it overflows.
    def detach_socket
      return false unless @monitor.synchronize { @live && !@stopped }

      @feed.detach
      return false unless @feed.attach(@context.realtime_opener(@realtime, items: LIFECYCLE_ITEMS))
      @monitor.synchronize { @live = false }
      unsubscribe_transcript
      unsubscribe_progress
      true
    end

    # A listener is handed every event from now on — never a replay: the
    # durable answer is the trace, and this is latency sugar over it.
    def listen(&handler)
      @monitor.synchronize do
        token = (@listener_sequence += 1)
        @listeners[token] = handler
        token
      end
    end

    def forget(token)
      @monitor.synchronize { @listeners.delete(token) }
    end

    def listeners? = @monitor.synchronize { @listeners.any? }

    # THE TURN IS OVER: it completed or was canceled, or it failed on a
    # loop whose own row is terminal. A turn-shaped `failed` on a live
    # loop is a hold — `complete` as a level — and a retry or an answer
    # reopens it. A failed answer without a backing loop has no held work
    # to resume and is already settled.
    def turn_settled?
      @monitor.synchronize do
        @complete && (@status != "failed" || @loop.nil? || LOOP_TERMINAL_STATUSES.include?(@loop_status))
      end
    end

    # THE OTHER FEED'S ENDING. `turn_settled?` is the EVENTS
    # feed's word — where the turn GOT TO — while what a person READS ends
    # on the transcript feed: the `stream_reset` and the remainder a settle
    # fans. The two are separate subscriptions and the terminal can beat the
    # settle by milliseconds, so a reader that ended on the first printed
    # nothing while `rho watch` printed the whole reply.
    #
    # There is nothing to wait for when nothing will deliver it: with no
    # transcript pump (streaming off, no socket, nobody live) and on a LOOP
    # host — whose feed carries settled rounds and no turn at all, since only
    # a conversation publishes one — this is true the moment it is asked.
    def transcript_settled?
      @monitor.synchronize do
        next true unless streaming? && @host.outlives_turn?
        next true if @turn.nil?
        next true unless current_turn_visible?

        @transcript_settled.include?(@turn)
      end
    end

    # NOTHING FURTHER WILL COME — which is the host's to say: a standalone
    # loop ends with its one turn; a conversation stands past every turn
    # terminal, so its follow does too (`rho stop` cancels a turn, forgetting
    # the host ends the follow).
    def settled? = !@host.outlives_turn? && turn_settled?

    def stopped? = @monitor.synchronize { @stopped }

    def stop
      @monitor.synchronize { @stopped = true }
      @gate&.cancel!
      @feed.stop
      unsubscribe_transcript
      unsubscribe_progress
      self
    end

    # Installed once the turn's backing loop is known: the
    # `:turn_follow` hook fires then, not at the open.
    def gate=(gate)
      @monitor.synchronize { @gate = gate }
    end

    def gate = @monitor.synchronize { @gate }

    # Ask the gate to look, on the host's reactor, at the LOOP it is bound
    # to; the gate decides from that loop's trace, not from here.
    def nudge
      return if @spawner.nil?

      gate, context = @monitor.synchronize { [@gate, gate_context] if gate_applies? }
      return if gate.nil?

      @spawner.call { gate.reconsider(context) }
    end

    def snapshot
      @monitor.synchronize do
        Snapshot.new(
          public_id: public_id, host_type: @host.type, status: @status,
          loop_status: @loop_status, failure_reason: @failure_reason,
          failure_reason_key: @failure_reason_key, loop: @loop, turn: @turn, turn_kind: @turn_kind,
          loops: @loops.dup, attention: @attention, tasks: @tasks.values, text: @text.text,
          text_length: (@text.length if @text.length.positive?),
          reasoning: (@reasoning.text unless @reasoning.empty?),
          sequence: @feed.position.sequence, complete: @complete, live: @live,
          until: @gate&.to_h, mailed: @mailed.dup, runner: @runner, blocked: @blocked,
          children: @children&.dup, frames: (@frames.dup unless @frames.empty?)
        )
      end
    end

    private

      # A replayed terminal can precede recovery of its expired prefix. A
      # transient read failure must retry that recovery before ending pumps.
      def stopped_or_settled? = @monitor.synchronize { @stopped || (!@replay_truncated && settled?) }

      def recovery_interval = turn_settled? && transcript_settled? ? IDLE_POLL_SECONDS : POLL_SECONDS

      # Under the monitor. A gate bound to a loop this turn is not backed
      # by is a gate for a turn that is over.
      def gate_applies?
        !@gate.nil? && (@gate.loop_public_id.nil? || @gate.loop_public_id == @loop)
      end

      # The loop's own context for the gate: built for a conversation, the
      # host's own for a loop.
      def gate_context
        return @context if @loop_context.nil? || @loop.nil?

        @loop_context.call(@loop)
      end

      # An item type this daemon predates advances the position and means
      # nothing here. THE DELTAS ARE NOT ON THIS FEED: `text_delta` and
      # `stream_reset` ride the host's TRANSCRIPT stream (`follow_transcript`),
      # and the arms that read them here were dead the whole time — the
      # events feed has never carried one.
      def apply(event)
        @monitor.synchronize { mark_replay_gap if event.sequence > replayed_sequence + 1 }
        case event.type
        when "turn_status" then commit_turn(event.payload)
        when "turn_variant" then commit_variant(event.payload)
        when "task_status" then commit_task(event.payload)
        when "round_result" then commit_round(event.payload)
        when "attention_required" then commit_attention(event.payload)
        when "input_accepted" then commit_mail(event.payload)
        when "input_blocked" then commit_blocked(event.payload)
        when "runner_bound" then commit_runner(event.payload)
        when "task_deadline_extended" then commit_extension(event.payload)
        when "visibility", "soft_delete" then commit_view_state(event.payload)
        when "turn_deleted" then commit_deleted_turn(event.payload)
        when "conversation_ended" then commit_end(event.payload)
        else nil
        end
        if @replay_truncated && event.type == "turn_status" && event.payload.key?("status")
          @replay_turn = @turn
        end
        nudge_gate(event)
        notify(event)
      end

      # End this following, not the kernel's work. A gate waiting on the host
      # is released and the daemon forgets its local resources. The lifecycle
      # item still fans to current listeners as any other durable event does.
      def end_host
        ended = @monitor.synchronize do
          next false if @stopped

          @stopped = true
        end
        return unless ended

        stop
        @on_ended&.call(self)
      end

      # Outside the monitor: a listener writes to a socket, which can block or
      # raise, and one slow reader must not stall the loop everybody watches.
      # A raising handler is dropped — it is somebody's connection, not the work.
      def notify(event)
        handlers = @monitor.synchronize { @listeners.dup }
        return if handlers.empty?

        handlers.each do |token, handler|
          handler.call(event)
        rescue StandardError => error
          @monitor.synchronize { @listeners.delete(token) }
          @logger&.info("host.listener_dropped", host: public_id,
                        error_class: error.class.name)
        end
      end

      # The table is the gate's FILTER: a fetch is spent only when it
      # shows a check parked with nothing else live.
      def nudge_gate(event)
        gate, tasks = @monitor.synchronize do
          next if @complete || !gate_applies?

          [@gate, @tasks.values]
        end
        return if gate.nil? || !gate.worth_a_look?(tasks)

        nudge
      end
  end
end
