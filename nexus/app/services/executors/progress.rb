module Executors
  # THE EXECUTOR-ORIGINATED FRAME ("live
  # progress"): what is only useful while it happens rides the host's
  # `progress` feed as an EPHEMERAL FRAME — nothing stored, no replay, a
  # late subscriber sees what follows. ONE door, two key kinds, each with
  # its own fence, one polymorphic predicate per fence:
  #
  # - a TASK-keyed frame `{run_public_id, task_key, claim_token,
  #   text_tail?, structured?}` posts INSIDE a claim: the poster must be the
  #   row's current claimant — the executor that took it AND the token the
  #   take minted (`Parked#claimed_by?`) — else `not_claimant`; a row
  #   no longer `dispatched` is accepted and the frame dropped, because a
  #   settled row's progress is nobody's news;
  # - a HOST-keyed process frame `{conversation_public_id |
  #   run_public_id, process_id, source: {run_public_id, task_key,
  #   claim_token}, lines[], exit?}` proves the claim that started the
  #   process. That source task may have settled, but its target, claimant,
  #   token and host must still match. The host's current default is irrelevant.
  #   `process_id` is opaque and never read; the source token never rides out.
  #
  # THE CADENCE IS THE DOOR'S (`ProgressController`'s `rate_limit`):
  # one frame per key per `MIN_INTERVAL_MS`, keyed by
  # `key_of` — the frame's KEY BYTES and the poster's own id, so a
  # stranger's flood cannot eat a claimant's slot — taken BEFORE this
  # service reads a row; a faster poster is answered 202 there and never
  # reaches here. What this service drops of its own is a claim-keyed frame
  # for a row no longer `dispatched`: accepted with no frame published,
  # because a settled row's progress is nobody's news — never a refusal.
  #
  # THE CADENCE STORE IS PROCESS-LOCAL and lives here beside the
  # interval it bounds: an `ActiveSupport::Cache::MemoryStore`, its
  # `increment` atomic under the store's own monitor, the same in every
  # environment and with no configuration read. NOT `Rails.cache`: under
  # `solid_cache_store` a counter is a transaction and a `SELECT … FOR
  # UPDATE` on `solid_cache_entries` on EVERY frame, dropped ones included.
  # Process-local means the bound is N × one frame per key per interval for
  # N Puma workers: `config/puma.rb` declares no `workers` today (three
  # threads, one process), so N = 1 and this comment is where N is named;
  # the door's purpose — bounding cable rows — is met either way.
  #
  # THE KERNEL STAMPS `type`, `executor_public_id`, `at` (milliseconds, so
  # the bound is observable on the wire) and, inside a claim, `tool_name`;
  # the executor sends the key and the payload. The envelope out is
  # `{frame}` — deliberately NOT `{event}` — so the disjointness from every
  # durable item type is true by construction; `TYPES` is pinned disjoint
  # from the event vocabularies by constant reference in progress_test.
  # The accepted answer's value is the frame as broadcast, nil when dropped.
  module Progress
    # The floor of the cadence per key per kernel process. rho-runner
    # MIRRORS it (`Rho::Runner::Progress::MIN_INTERVAL_MS`) and the contract
    # pack pins the two equal (`size_bounds.json#/progress_min_interval_ms`).
    MIN_INTERVAL_MS = 250
    MIN_INTERVAL = (MIN_INTERVAL_MS / 1000.0).seconds
    # The two frame types this door mints — a constant on the service, not
    # a lib module; the kernel's own three are `Conversations::ProgressStream::KERNEL_TYPES`, and the pack lists the feed's seven
    # once (`conversations.json#/progress_frame_types`).
    TYPES = %w[executor_progress process_output].freeze
    # What each key kind carries out, beside the key and the stamps. The
    # kernel TYPES the payload and judges nothing in it (the tool-argument
    # rule): a member of the wrong type is `invalid_frame`.
    TASK_PAYLOAD = { "text_tail" => String, "structured" => nil }.freeze
    PROCESS_PAYLOAD = { "lines" => Array, "exit" => Integer }.freeze
    # `exit` alone admits `null`: a signal death has no status.
    NULLABLE = %w[exit].freeze

    RATE = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

    module_function

    def call(executor:, frame:)
      frame = Hash.try_convert(frame)
      return Outcome.refused(:invalid_frame) if frame.nil?
      return Outcome.refused(:frame_too_large) unless Nexus::SizeBounds.json_within?(:envelope_bound, frame)

      kind = key_kind(frame)
      return Outcome.refused(:invalid_frame) if kind.nil?

      # Stamped at RECEIPT, before the fence: the gap between two admitted
      # frames' `at` is then the door's bound itself, not the bound plus
      # whatever the fence's reads took.
      at = now
      kind == "task" ? task_frame(executor, frame, at) : process_frame(executor, frame, at)
    end

    # THE TWO SHAPES OUT, pure over their facts, so the contract pack
    # renders the projection the door serves. The key, then the stamps,
    # then the payload; nothing else rides.
    def executor_progress(run_public_id:, task_key:, tool_name:, executor_public_id:, at:, payload:)
      {
        "type" => "executor_progress",
        "run_public_id" => run_public_id, "task_key" => task_key, "tool_name" => tool_name,
        "executor_public_id" => executor_public_id, "at" => at,
      }.merge(payload)
    end

    def process_output(host_type:, host_public_id:, process_id:, executor_public_id:, at:, payload:)
      {
        "type" => "process_output",
        "#{host_type}_public_id" => host_public_id, "process_id" => process_id,
        "executor_public_id" => executor_public_id, "at" => at,
      }.merge(payload)
    end

    # THE CADENCE KEY the door limits on: the key kind, the poster's own
    # id and the frame's key bytes; nil for a frame keyed by neither kind
    # (or no object at all) — such a frame has no cadence, the door
    # refuses it `invalid_frame` without a row read.
    def key_of(executor, frame)
      frame = Hash.try_convert(frame)
      kind = frame && key_kind(frame)
      return nil if kind.nil?

      [kind, executor.public_id, *key_bytes(kind, frame)].join(":")
    end

    # The key names the kind: a `task_key` is a claim's frame, a
    # `process_id` a host's; a frame with both or neither is malformed.
    def key_kind(frame)
      task = frame.key?("task_key")
      process = frame.key?("process_id")
      return nil if task == process
      return "task" if task && string?(frame["run_public_id"]) && string?(frame["task_key"])
      return "process" if process && string?(frame["process_id"]) && host_key?(frame)

      nil
    end

    def key_bytes(kind, frame)
      if kind == "task"
        [frame["run_public_id"], frame["task_key"]]
      else
        [frame["conversation_public_id"] || frame["run_public_id"], frame["process_id"]]
      end
    end

    def host_key?(frame)
      string?(frame["conversation_public_id"]) != string?(frame["run_public_id"])
    end

    # Asked by conversion, not inspection (the closed-shapes rule): a key
    # member is a non-empty String or the frame is malformed.
    def string?(value) = !String.try_convert(value).to_s.empty?

    # The claim's own fence, lock-free (Extend#claimant?'s rule): the
    # address AND the token. A row that settled while the poster ran is
    # accepted with nothing published, never a refusal — the runner
    # still holds a true claim token for work the kernel has moved past.
    def task_frame(executor, frame, at)
      agent_run = runs(executor).find_by(public_id: frame["run_public_id"])
      return Outcome.refused(:not_found) if agent_run.nil? || agent_run.tombstoned?

      node = agent_run.agent_run_tasks.find_by(node_key: frame["task_key"], type: AgentRunTasks::PARKED_TYPES)
      return Outcome.refused(:not_found) if node.nil?
      return Outcome.refused(:not_claimant) unless node.claimed_by?(executor, token: frame["claim_token"])
      return Outcome.accepted unless node.status == "dispatched"

      payload = payload_of(frame, TASK_PAYLOAD)
      return Outcome.refused(:invalid_frame) if payload.nil?

      publish(agent_run.host, executor_progress(
        run_public_id: agent_run.public_id, task_key: node.node_key, tool_name: node.tool_name,
        executor_public_id: executor.public_id, at: at, payload: payload
      ))
    end

    # Source-claim proof remains valid after settlement and default changes.
    # Retry rotates the claim; pruning removes it. Neither can authorize a
    # new process frame using the old token.
    def process_frame(executor, frame, at)
      source = Hash.try_convert(frame["source"])
      return Outcome.refused(:invalid_frame) if source.nil? ||
        !%w[run_public_id task_key claim_token].all? { |key| string?(source[key]) }

      host = host_of(executor, frame)
      return Outcome.refused(:not_found) if host.nil?

      source_run = runs(executor).find_by(public_id: source.fetch("run_public_id"))
      return Outcome.refused(:not_found) if source_run.nil? || source_run.tombstoned?

      task = source_run.agent_run_tasks.find_by(node_key: source.fetch("task_key"), type: AgentRunTasks::ToolTask.sti_name)
      return Outcome.refused(:not_found) if task.nil?
      return Outcome.refused(:not_claimant) unless
        task.claimed_by?(executor, token: source.fetch("claim_token")) &&
        task.target_executor_id == executor.id && task.target_executor_public_id == executor.public_id &&
        source_run.host == host

      payload = payload_of(frame, PROCESS_PAYLOAD)
      return Outcome.refused(:invalid_frame) if payload.nil?

      publish(host, process_output(
        host_type: Nexus::RealtimeStreams.resource_type(host), host_public_id: host.public_id, process_id: frame["process_id"],
        executor_public_id: executor.public_id, at: at, payload: payload
      ))
    end

    def host_of(executor, frame)
      if frame.key?("conversation_public_id")
        Conversation.where(account_id: executor.account_id).find_by(public_id: frame["conversation_public_id"])
      else
        # A run-keyed frame lands on the run's host: its conversation,
        # or the standalone run itself. As with `TranscriptStream`,
        # a conversation-backed run publishes on its conversation's channel.
        runs(executor).find_by(public_id: frame["run_public_id"])&.host
      end.then { |host| host unless host&.tombstoned? }
    end

    def runs(executor) = AgentRun.where(account_id: executor.account_id)

    # The named payload members alone, typed by CONVERSION (`try_convert`,
    # never a probe) and otherwise untouched; a `nil` expectation admits
    # any JSON value, and `NULLABLE` names the one member that admits
    # `null`. Nothing else in the frame rides out — the key is the
    # kernel's to spell.
    def payload_of(frame, shape)
      shape.each_with_object({}) do |(name, type), payload|
        next unless frame.key?(name)

        value = frame[name]
        if type && !(value.nil? && NULLABLE.include?(name))
          value = type.try_convert(value)
          return nil if value.nil?
        end
        return nil if name == "lines" && !value.all? { |line| String.try_convert(line) }

        payload[name] = value
      end
    end

    # Milliseconds, as a String the JSON encoder leaves alone: the
    # per-key bound is observable on the wire only at that precision.
    def now = Time.current.utc.iso8601(3)

    def publish(host, frame)
      RealtimeEvents::Broadcast.frame(
        resource_type: Nexus::RealtimeStreams.resource_type(host), resource_public_id: host.public_id, frame: frame
      )
      Outcome.accepted(frame)
    end
  end
end
