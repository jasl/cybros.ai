module Conversations
  # THE KERNEL'S OWN NARRATION, EPHEMERAL:
  # a frame on the host's `progress`
  # feed for a fact NO durable item and NO settled snapshot carries at the
  # instant it happens — an attempt dialled (`round_started`), a tool row
  # live with its name (`step_started`), the claimant (`step_claimed`).
  # Three words, one producer, two seams: the hosted sink's
  # `on_attempt_started` and `AgentRuns::Transition.node`. A round's or a
  # call's END is no frame — the settled `round` / `call` snapshot on
  # `transcript` carries `started_at` / `completed_at`, and a second copy
  # with a clock is the twin the one-implementation rule forbids. A
  # compaction's arming is the durable `context_compacted`; a long call's
  # extend is `task_deadline_extended`; a direct reply narrates
  # `turn_status`, its deltas and its settled `turn` — none is a frame.
  #
  # NOT `AgentRun::Narration`: that funnel buffers durable items into
  # `ConversationEvent::Append` at before_commit, and a frame must never
  # become a row. The one publish is `RealtimeEvents::Broadcast.frame`
  # under `{frame}`; the keys and the hidden gate are the transcript's own
  # `Source`, so the two feeds correlate by the same fields and a `hidden`
  # task reaches this feed exactly as it reaches the transcript: not at all.
  module ProgressStream
    # The three facts with no durable carrier at their instant. Disjoint
    # by exact string from every event vocabulary and from
    # `TranscriptStream::ITEM_TYPES` (`tool_call_started` there is the
    # MODEL's first fragment naming a call before any row exists;
    # `step_started` is the KERNEL's dispatch of the row) — pinned by
    # constant reference in executors/progress_test beside the door's own.
    KERNEL_TYPES = %w[round_started step_started step_claimed].freeze
    # The status words a tool row's change narrates: started (the kernel's
    # own job, an executor's claim, a person) and held for an approver —
    # both are news to a status bar reading only `lifecycle` + `progress`,
    # which learns the tool's NAME from nowhere else. A terminal is the
    # settled snapshot's.
    NEWS_STATUSES = (AgentRunTask::STARTED_STATUSES + AgentRunTask::HELD_STATUSES).freeze

    module_function

    # THE THREE SHAPES OUT, pure over their facts, so the contract pack
    # renders the fixtures the SDK is settled against. The type, the
    # Source's keys, the fact, then the stamp.
    def round_started_frame(keys:, mainline:, attempt:, model:, request_bytes:, at:)
      { "type" => "round_started" }.merge(wire_keys(keys)).merge(
        "mainline" => mainline, "attempt" => attempt, "model" => model, "request_bytes" => request_bytes, "at" => at
      )
    end

    def step_started_frame(keys:, tool_name:, status:, at:)
      { "type" => "step_started" }.merge(wire_keys(keys)).merge("tool_name" => tool_name, "status" => status, "at" => at)
    end

    def step_claimed_frame(keys:, tool_name:, executor_public_id:, at:)
      { "type" => "step_claimed" }.merge(wire_keys(keys)).merge(
        "tool_name" => tool_name, "executor_public_id" => executor_public_id, "at" => at
      )
    end

    # SEAM 1 — an attempt dialled (`ExecuteAttempt#dispatch`, through the
    # hosted sink that resolved its Source and KEPT the node): the round's
    # key and mark, the attempt's ordinal, the model, and the sealed
    # request's size — one `pick` beyond what the sink already holds. A
    # direct reply's Source carries no node and narrates nothing here.
    # Published now: the start claim committed before the dial.
    def round_started(source, node, attempt)
      return if node.nil? || source.hidden

      invocation = attempt.model_invocation
      publish(source.host, round_started_frame(
        keys: source.keys, mainline: node.continuation_source != AgentRuns::Tasks::Compile::BRANCH,
        attempt: attempt.ordinal, model: "#{invocation.provider_id}/#{invocation.model_ref}",
        request_bytes: node.sealed_request_bytes, at: now
      ))
    end

    # SEAM 2 — a committed transition (`AgentRuns::Transition.node`).
    # DECIDED EAGERLY, PUBLISHED LATE: `saved_changes` is read at the call —
    # the write just made is the last save of THIS call — and the frames
    # are built and captured now; only the broadcast rides after_commit,
    # so a rolled-back transition publishes nothing, and a later save of
    # the same object inside the transaction (`Transition.nodes` loops a
    # row per node) cannot change what was decided. A tool row whose
    # status CHANGED into a started or held word is `step_started` (an
    # approval-gated call fires it twice — the park and the release — and
    # both are news; a reader upserts the call's live status); a tool row
    # whose claimant became non-nil is `step_claimed`. Nothing at a
    # terminal (the settled snapshot's), nothing on a round, an await or
    # a join — a wide fan's settles and a tree cancel cost no frame.
    def transition(node)
      return unless node.tool_call?

      changes = node.saved_changes
      status = changes["status"]&.last
      started = status && NEWS_STATUSES.include?(status)
      claimed = changes["claimed_by_executor_id"]&.last.present?
      return unless started || claimed

      source = TranscriptStream.task_source(node)
      return if source.hidden

      frames = transition_frames(node, source.keys, status: (status if started), claimed: claimed)
      host = source.host
      ApplicationRecord.current_transaction.after_commit do
        frames.each { |frame| publish(host, frame) }
      end
    end

    def transition_frames(node, keys, status:, claimed:)
      at = now
      frames = []
      if status
        frames << step_started_frame(keys: keys, tool_name: node.tool_name,
          status: AgentRuns::TaskProjection.public_status(status), at: at)
      end
      if claimed
        frames << step_claimed_frame(keys: keys, tool_name: node.tool_name,
          executor_public_id: node.claimed_by_executor_public_id, at: at)
      end
      frames
    end

    def wire_keys(keys) = keys.transform_keys(&:to_s)

    # ISO 8601 with millisecond precision, kept as a String so JSON encoding
    # preserves the same precision as executor frames.
    def now = Time.current.utc.iso8601(3)

    # The one publish: the executor door's seam, whose rescue is the
    # rule — a cable that is down costs a frame, never the work.
    def publish(host, frame)
      RealtimeEvents::Broadcast.frame(
        resource_type: Nexus::RealtimeStreams.resource_type(host), resource_public_id: host.public_id, frame: frame
      )
    end
  end
end
