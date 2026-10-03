module CybrosAgent
  module Api
    # Typed projections of the EXECUTOR BOUNDARY — the half of the
    # agent-loop surface an executor speaks, on its own plane.
    #
    # THE INBOX IS THE TRUTH AND THE CABLE IS A NUDGE. Nexus publishes
    # `work_available` on the EXECUTOR's own channel
    # (`AgentAPI::V1::ExecutorInboxChannel`, no params — the credential
    # names the address) naming a kind, a loop, a task key and a tool name,
    # and `work_canceled` to the claimant; neither carries anything
    # executable. The arguments and the claim token live only behind the
    # HTTP doors. Listing recovers available work; claim status recovers a
    # missed cancellation for an execution still held locally. There is no blocking
    # spelling here for the same reason there is none on OneShots: hiding a
    # poll loop inside a method hides the deadline and the backoff from the
    # only code that can choose them.

    # Whom a row is addressed to: a role, and the executor when
    # the kernel bound one. A pool row names the role alone.
    # The addressee's presence and contact sample ride beside its id on the
    # task read; the inbox row names neither. Additive on the
    # constructor, as the row is.
    AddressedTo = Data.define(:role, :executor_public_id, :presence, :last_seen_at) do
      def initialize(role:, executor_public_id: nil, presence: nil, last_seen_at: nil)
        super
      end
    end

    # Who holds a claimed row: the claimant's public-id
    # snapshot, as the loop task read names it beside `addressed_to`.
    ClaimedBy = Data.define(:executor_public_id)

    # One inbox row, as the inbox lists it and as a granted claim answers
    # with it — the same projection from both doors, so a runner that
    # claimed and a runner that listed are looking at the same object.
    #
    # `kind` is the row's inbox kind — `tool_call` for a parked tool row,
    # `ask` for a model's question addressed to the agent application
    # (`prompt` carries the question, no tool field, never claimed, committed with no claim token), `approval` a tool call
    # resting for an approver on the addressed agent application's inbox
    # (never claimed — `claim` is 409 `not_claimable_kind` — its end is the member plane's `approve`/`deny` or the 24 h park clock) — and a word this gem predates is carried, not refused.
    # `claimed` is EVER claimed in this generation: a lapsed claim is not
    # re-granted, expiry is the sweep's alone.
    #
    # `timeout_ms` is THE PARK'S BUDGET, the number the kernel cut
    # `deadline_at` from — the call's authored timeout, else the announced
    # one, else the kernel's; an ask's own, at most 24 h; an approval's
    # 24 h hold — stated on every parked row so a runner names the budget
    # it was held to without reading a clock. A claim or an extension
    # moves `deadline_at` and never this.
    #
    # `effect_profile` is THE ONE ROW KIND THAT CARRIES IT: on an approval
    # row, the profile frozen on the held call — what the approver reads
    # before granting; nil on every runner row (a runner reads its own announcement).
    #
    # `scope` is THE KERNEL'S STAMP ON AN OVERRIDDEN KERNEL ROW:
    # Memory carries `{bindings: [{name, scope, access, <scope>_public_id}]}`;
    # skill carries `{workspace_public_id, conversation_public_id | nil, user_public_id}`.
    # The kernel states whose rows are reachable beside `tool_input`, which passes
    # through untouched. Present only when the row's tool is a kernel name
    # — one the loop's workspace overrides to a tools provider, or a
    # `skill` load addressed to the executor that announced the name (the
    # two ways a kernel name reaches the inbox) — and nil on every other
    # row. `tool_alias` is the spelling the model called the tool by when
    # the profile declared an alias of a kernel tool (Claude Code's `Skill`
    # for `skill`); nil on a plain call. An opaque
    # frozen map, not a typed struct: the runner hands it to a handler and
    # the provider decides what it means (a memory provider keys its store
    # by it and never guesses from the arguments or expands omitted roots).
    # `workspace_public_id` names the loop's workspace on every row,
    # including standalone loops and nested children. Consumers use this
    # kernel-owned scope rather than their current default or a local tree.
    # `conversation_public_id` rides EVERY row: the loop's conversation,
    # nil for a standalone loop — the kernel saying whose row this is, so
    # a runner that holds something across calls (a process it started)
    # owns it by the conversation and never resolves the loop itself.
    # `parent_public_id` rides beside it the same way: the conversation's PARENT — the kernel's snapshot on
    # a spawned child — nil on a root conversation's row and a standalone
    # loop's, so a runner elsewhere resolves a child's environment by its
    # parent's received binding with no relay in the path.
    # `options`/`multi` are an ask row's choices as data: the strings to show the person and whether several
    # may be taken; nil on an ask that gave none and on every other row.
    InboxTask = Data.define(
      :kind, :agent_loop_public_id, :workspace_public_id, :conversation_public_id, :parent_public_id, :task_key, :prompt, :options,
      :multi, :tool_name, :tool_alias, :tool_input, :scope, :tool_call_id, :started_at, :deadline_at, :timeout_ms,
      :claimed, :addressed_to, :effect_profile
    ) do
      # A consumer building a row itself (a runner's test double) may leave
      # out the members its row has no value for, and they read as nil, as
      # they do off the wire. Required identity and kind have no defaults:
      # the kernel writes them on every executable row.
      def initialize(workspace_public_id:, addressed_to: nil, prompt: nil, options: nil, multi: nil, tool_name: nil,
                     tool_alias: nil, scope: nil, effect_profile: nil, conversation_public_id: nil,
                     parent_public_id: nil, **members)
        super(workspace_public_id: workspace_public_id, addressed_to: addressed_to,
              prompt: prompt, options: options, multi: multi,
              tool_name: tool_name, tool_alias: tool_alias, scope: scope, effect_profile: effect_profile,
              conversation_public_id: conversation_public_id, parent_public_id: parent_public_id, **members)
      end

      def claimed? = claimed
    end

    # A granted claim: the work, plus the bearer proof the commit door
    # checks. THE TOKEN ROTATES on every claim, so a runner returning from
    # the dead holding an old one is refused rather than overwriting whoever
    # holds the work now — and the deadline is the claim's only clock. There
    # is no heartbeat to send; a claimant still at work EXTENDS that one
    # clock (`ExecutorTaskContext#extend`) and reads this same shape back,
    # `deadline_at` moved.
    ClaimedTask = Data.define(:task, :claim_token, :deadline_at)

    ClaimStatus = Data.define(:active) do
      def active? = active
    end

    # ---- THE AUTHOR HALF ----
    #
    # The executor half above could execute tool work but nothing here could
    # AUTHOR any: this SDK shipped the claim/commit door and no way to
    # create the loop those doors serve, so every client that wanted one
    # had to hand-write HTTP. A loop is the kernel's unit of agentic work;
    # not being able to start one from Ruby is what "no verb starts a
    # loop" meant.
    #
    # Task-grained on the write, like the surface it mirrors: nothing here
    # authors an edge. On a read a task names what it was authored after and
    # still waits for, and `AgentLoopGraph` carries the whole picture; the
    # engine's mechanism — spine mark, countdowns, generations, the mutation
    # counter — never appears.

    # One task as the trace projects it. `status` is the PRODUCT's word:
    # the engine's `queued` reads as `waiting`, and this side does not
    # translate it back.
    #
    # `result` is the OUTCOME SUMMARY — a small object, never the output.
    # The trace stays lean, so a task's bytes ride only on the single-task
    # read; what appears here is the shape of how it ended
    # (`{"finish_quality" => ...}` on a round — `refused` or `blocked` with
    # the provider's `refusal_category` beside it on a step a provider
    # declined, which FAILED with the error key `model_refused` —
    # `{"resolved" => true}` on a settled park, `{"join_failure" => ...}`
    # on a join). A round the kernel moved to another model carries
    # `model_change` — `{from, reason, category?}`, what this execution
    # replaced — from the switch on, so a WAITING or RUNNING round may
    # already carry a `result`: `reason` is `model_refused` when the
    # answerer's declared fallback re-ran a declined step. This gem typed
    # it as a String for its whole life, which meant a completed loop —
    # any loop whose tasks had settled — raised `MalformedResponse` on
    # the way in. No fixture carried the field, so nothing caught it
    # until a daemon read back a run a real model had finished.

    # THE ONE COPY OF THE KERNEL'S TASK VOCABULARY on the client side. rho
    # holds none of its own and derives from these, because a second
    # hand-written list in a second repository is exactly the artifact
    # that made a park invisible to rho's acceptance gate.
    #
    # At module level on purpose: a constant assigned inside a
    # `Data.define` block belongs to the lexical scope rather than to the
    # class the block configures, so writing them there would have put two
    # generically-named constants on `Api` by accident. Named for their
    # axis instead, beside the only thing that reads them.
    #
    # `waiting` is the product's word for the engine's `queued`; the other
    # ten cross the wire unrenamed.
    TASK_TERMINAL_STATUSES = %w[completed failed timed_out uncertain canceled skipped].freeze
    # Authored, and nothing spent on it yet.
    TASK_PRE_START_STATUSES = %w[waiting needs_approval].freeze
    # The LOOP's own terminal set — a different axis from a task's, and it
    # was hand-written in three places before this. No `failed`: the loop
    # never writes one — a reasoned cancel IS the loop failing, and the
    # TURN shape below carries the `failed` a hold or that cancel renders.
    LOOP_TERMINAL_STATUSES = %w[completed canceled].freeze
    # The TURN shape's terminal set — the status a host's
    # `turn_status` carries and a standalone loop renders beside its row.
    TURN_TERMINAL_STATUSES = %w[completed failed canceled].freeze

    # `after` is what a task was authored after, as task keys, at every
    # status. `waiting_on` is what a task that has not started is still
    # waiting for — empty once it starts or settles, because from then on
    # its status says what it waits on (the kernel, a machine, a person)
    # or that it is done.
    # `mailed_at` is present only on a background answer that outlived its
    # turn and was mailed to the conversation as the kernel's own input.
    # `addressed_to` and `claimed_by` are a started call's addressee (the
    # role alone for a pool row) and its claimant; absent on everything else.
    # `approval` is the stage's fact on a tool call —
    # `{origin, decided_by?, decided_at}`, `origin` one of `mode | rule |
    # author | kernel | human | agent` — absent until the call was decided;
    # a denial's reason is the row's `error.detail`, not repeated here.
    LoopTask = Data.define(
      :key, :kind, :status, :lifetime, :after, :waiting_on, :on_failure, :failure_resolution,
      :retry_budget, :tool_name, :result, :error,
      :visibility, :created_at, :started_at, :completed_at, :model, :mailed_at,
      :addressed_to, :claimed_by, :approval, :wake
    ) do
      def initialize(after: [], waiting_on: [], retry_budget: 0, model: nil, mailed_at: nil,
                     addressed_to: nil, claimed_by: nil, approval: nil, **) = super

      def waiting? = status == "waiting"
      # NARROW, AND HONEST BECAUSE OF IT: the kernel is doing this one —
      # a model round, or a kernel tool in one of nexus's own jobs. A
      # call out at somebody's machine is `dispatched`, and a question
      # waiting on a person is `awaiting_input`. Ask `started?` for
      # "is this in flight at all".
      def running? = status == "running"
      # `uncertain` is adjudicable like a failure — the kernel's
      # `retry`/`abandon` rule — which is what `repairable_tasks` reads.
      def failed? = %w[failed timed_out uncertain].include?(status)
      def terminal? = TASK_TERMINAL_STATUSES.include?(status)
      def live? = !terminal?
      # BEGUN: something is being waited on, whether the kernel, a
      # machine holding a bearer proof, or a person.
      def started? = live? && !TASK_PRE_START_STATUSES.include?(status)

      # WHAT THIS TASK IS, asked the way the kernel asks it. `kind` is the
      # wire spelling of a node type and these are its three questions —
      # named identically to the kernel's own predicates, so a client
      # reading a trace and the engine writing it use one vocabulary
      # instead of string literals spread across both.
      def round? = kind == "model_task"
      def tool_call? = kind == "tool_task"
      def await? = kind == "await_task"

      # How a model step's answer finished, read off the summary: nil on a
      # clean finish and on every other kind. `refused?` is a provider
      # declining the step — its classifier, or a content stop — and the
      # step failed for it; `refusal_category` is the provider's own word,
      # nil when it named none.
      def finish_quality = result&.fetch("finish_quality", nil)
      def refusal_category = result&.fetch("refusal_category", nil)
      def refused? = %w[refused blocked].include?(finish_quality)
      # What this round's current execution replaced when the kernel moved
      # it to another model — `{"from", "reason", "category"?}`, the row's
      # own `model` naming where it went — nil when it never moved.
      def model_change = result&.fetch("model_change", nil)
    end

    # The turn shape a loop renders beside its own row: a
    # standalone loop's `status` is the frozen turn algebra over its rows
    # (pending, running, failed, completed, canceled); a loop-backed loop's
    # is its TURN row's, and the two ids say which turn. `model` is THE STATED PLACE a follower reads the model a
    # loop-backed turn's main reply currently runs on, including a model
    # change at retry — as the loop's `{model, reasoning_effort}`
    # hash, `model` the catalog ref; nil on a standalone loop.
    LoopTurn = Data.define(:status, :failure_reason_key, :public_id, :conversation_public_id,
      :answering_user_public_id, :model) do
      def initialize(failure_reason_key: nil, public_id: nil, conversation_public_id: nil,
                     answering_user_public_id: nil, model: nil, **) = super

      # The catalog ref alone, `provider/model`; nil when the turn names none.
      def model_ref = model&.fetch("model", nil)

      def loop_backed? = !public_id.nil?
      def failed? = status == "failed"
      def terminal? = TURN_TERMINAL_STATUSES.include?(status)
    end

    # What a task carries when read on its own: the trace stays lean, so
    # the body rides only here.
    # `prompt` is the authored input: a model task's prompt or an ask's question.
    # An existing-task observation carries its source execution and task under `wait`.
    # `request_bytes` is the size a round's request was sealed with — the
    # kernel's stored fact, served on this read alone; nil on every other kind.
    # `instructions` is the system field a round was authored with under
    # `raw` (what a `model` step wrote, read back); nil otherwise.
    # `tool_definitions` is the round's frozen declaration, including alias
    # facts; [] means no tools, nil means the response carried no declaration.
    # `title` and `metadata` are the UI's two fields the executor committed
    # beside its result: the one-line header and the
    # model-invisible carrier (`metadata.checkpoint` reserved); served on
    # this read alone, nil when the executor sent none.
    # `options`/`multi` are an ask's choices as data,
    # beside `prompt`; nil when the asker gave none.
    # `output_preview` is the bounded preview the settled call's feed item
    # carries, so a reader that attached after the call settled renders what
    # a live follower rendered; nil where no output was stamped.
    LoopTaskDetail = Data.define(
      :task, :output, :content, :structured_content, :prompt, :options, :multi, :tool_input, :request_bytes,
      :instructions, :tool_definitions, :title, :metadata, :wait, :output_preview, :declaring_task_key
    ) do
      def initialize(prompt: nil, options: nil, multi: nil, tool_input: nil, request_bytes: nil,
                     instructions: nil, tool_definitions: nil, title: nil, metadata: nil, wait: nil, output_preview: nil,
                     declaring_task_key: nil, **) = super
    end

    # What the manual compaction door answers: the round it repaired, and
    # the summarizer it authored to do it.
    CompactedRound = Data.define(:task, :summary_task_key)

    # How far along, without a countdown in sight.
    # ONE COUNT PER STATUS, FLAT, which is what the kernel actually sends.
    # This asked for `counts`, `active_task_keys` and `blocked_task_keys`
    # — three fields no presenter has ever emitted — so every bucket read
    # empty and no test noticed, because the only fixture carrying the
    # field was written to match the projection instead of the wire.
    LoopProgress = Data.define(
      :total, :waiting, :needs_approval, :running, :dispatched, :awaiting_input,
      :completed, :failed, :canceled, :timed_out, :uncertain, :skipped
    ) do
      def initialize(total: 0, **counts)
        super(total:, **LoopProgress.members.difference([:total]).to_h { |m| [m, counts[m].to_i] })
      end
    end

    # The call to act: a loop that cannot proceed without a human or an
    # agent deciding something.
    LoopAttention = Data.define(:reason, :blocked_task_keys, :blocked_task_overflow) do
      def initialize(blocked_task_keys: [], blocked_task_overflow: nil, **) = super
    end

    # `runner` is the binding: where this loop's runner-kind calls land — a loop-backed loop
    # shows its conversation's — nil when unbound or reaped, absent on a listing.
    # `prompt_mechanism` is the EFFECTIVE word the loop's rounds were compiled under:
    # `default` on an assembled loop-backed turn, `raw` on a raw one; nil on a standalone
    # loop (its word is the kernel's assembly compiler's to settle) and on a listing.
    AgentLoop = Data.define(
      :public_id, :status, :failure_reason, :deliverable_task_key,
      :tasks, :task_progress, :attention, :turn, :input_queue, :started_at, :paused_at,
      :completed_at, :created_at, :updated_at, :runner, :prompt_mechanism, :details_pruned_at, :approval_mode
    ) do
      def initialize(tasks: [], turn: nil, input_queue: nil, runner: nil,
                     prompt_mechanism: nil, details_pruned_at: nil, approval_mode: nil, **) = super

      def running? = status == "running"
      def terminal? = LOOP_TERMINAL_STATUSES.include?(status)
      def needs_attention? = status == "needs_attention"
      def task(key) = tasks.find { |candidate| candidate.key == key }
      def deliverable = deliverable_task_key && task(deliverable_task_key)

      # WHAT AN ADJUDICATOR CAN ACT ON, by the kernel's own rule: a failure
      # nobody has resolved AND no policy resolves — an `absorb` failure is
      # settled the moment it is written and carries no stamp, so the
      # policy is read beside the stamp. Attention also names asks and
      # approvals; retry and abandon select unresolved failures instead.
      def repairable_tasks
        tasks.select { |task| task.failed? && task.failure_resolution.nil? && task.on_failure != "absorb" }
      end
    end

    # A created loop, and whether the receipt answered a REPLAY. An exact
    # repeat returns the standing loop rather than refusing — which is the
    # whole point of sending an idempotency key.
    CreatedAgentLoop = Data.define(:agent_loop, :receipt, :replayed) do
      def replayed? = replayed
    end

    # THE THREAD's page: spine rounds newest-first behind an opaque
    # cursor, returned in reading order — or, under `prefix:`, one
    # branch's rounds in the same shape with `spine` false on every row.
    AgentLoopTranscript = Data.define(:rounds, :next_before, :has_older) do
      include Enumerable

      def each(&) = rounds.each(&)
      def length = rounds.length
      def has_older? = has_older
    end

    # One call the round READ: `name` is what the model called, `tool` the
    # kernel's wire name beside it when they differ; the rest by presence.
    ThreadCall = Data.define(
      :task_key, :tool_call_id, :name, :tool, :status, :is_error, :title, :metadata,
      :output_preview, :output_bytes, :started_at, :completed_at
    ) do
      def to_h = super.compact
    end

    # The calls a round read: `items` the first of them in order, `count`
    # the whole — the overflow is the difference.
    ThreadCalls = Data.define(:count, :items) do
      def overflow = count - items.length
      def to_h = { count: count, items: items.map(&:to_h) }
    end

    # One row of the thread: the round's own answer, the kernel's spine
    # mark, the calls it read and `branches` — the call keys under which a
    # visible branch hangs, each expandable with `transcript(prefix:)`.
    # `compacted_before` / `pruned_before` are the compaction cut, by
    # presence; `error` a failed round's `{key, detail}`.
    ThreadRow = Data.define(
      :task_key, :spine, :status, :visibility, :text_preview, :text_bytes, :usage, :error,
      :compacted_before, :pruned_before, :started_at, :completed_at, :calls, :branches
    ) do
      def spine? = spine
      def to_h = super.merge(calls: calls.to_h).compact
    end

    # One node per task, hidden ones included (`visibility` rides so a UI may
    # filter), in the trace's vocabulary; `status` and `kind` carry verbatim so a
    # drawing does not go blank on the deploy that adds a word.
    # `spine` rides rounds alone: the kernel's own mark (`continuation_source`,
    # never a key's shape) — true on the conversation's thread, false on a
    # branch's rounds, nil on every other kind.
    # Material lists preserve reading order; `expansion_parent` names the task
    # that generated this node. Neither adds a scheduling dependency.
    GraphNode = Data.define(:key, :kind, :status, :visibility, :deliverable, :lifetime, :wake,
      :input_from, :result_from, :spine, :error_key, :join, :expansion_parent) do
      def initialize(spine: nil, error_key: nil, join: nil, expansion_parent: nil, **) = super

      def deliverable? = deliverable
      def spine? = spine == true
      def to_h = super.compact
    end

    # One dependency as task keys: the head waits for the tail to settle.
    # `structural` also marks placement in the authored sequence or branch.
    GraphEdge = Data.define(:from, :to, :structural)

    # `mermaid` is the kernel's own `flowchart TD` over the same nodes and
    # edges — derived once, server-side, so a terminal and a page draw the
    # same picture.
    AgentLoopGraph = Data.define(:nodes, :edges, :mermaid) do
      def node(key) = nodes.find { |candidate| candidate.key == key }
      def deliverable = nodes.find(&:deliverable?)
      # The heads an edge leaves `key` for, and the tails it was authored after.
      def after(key) = edges.select { |edge| edge.from == key }.map { |edge| node(edge.to) }
      def before(key) = edges.select { |edge| edge.to == key }.map { |edge| node(edge.from) }
    end

    # An append's answer — THE RECEIPT AND NOTHING ELSE. The door returns no
    # loop body, deliberately: growth is a write, and re-projecting the
    # whole trace on every append would make the cheap call the expensive
    # one. A caller that wants the new shape reads it.
    #
    # `steps` mirrors the request tree by key (a race's group carries the
    # barrier key the kernel minted) and `deliverable_task_key` names the
    # loop's answer after this envelope. `resolution_tokens` are BEARER
    # capabilities for the asks this envelope authored, keyed by task key,
    # and they travel ONLY here — the trace never carries them.
    AppendedTasks = Data.define(
      :accepted_task_keys, :steps, :deliverable_task_key, :revision, :resolution_tokens, :replayed
    ) do
      def initialize(accepted_task_keys: [], steps: [], deliverable_task_key: nil,
                     resolution_tokens: {}, **) = super

      def replayed? = replayed
    end

    # One top-level step of an authored envelope, as far as it has come:
    # `done` of `total` keys settled, and the one word for where it stands.
    LoopPhase = Data.define(:label, :keys, :done, :total, :status) do
      def completed? = status == "completed"
    end

    # Detached work nothing waits on: a tip still to settle, or one the
    # kernel already delivered as mail after the reply was final, which
    # carries `mailed_at`, the stamp of that delivery (nil on a tip still
    # to settle, where the kernel compacts the member away). `to_h`
    # compacts it the same way, so a host that re-serves the row serves
    # the kernel's own shape.
    BackgroundTask = Data.define(:key, :status, :mailed_at) do
      def to_h = super.compact
    end

    # HOW FAR ALONG: the phases in write order,
    # `current` the index of the first not yet completed (nil when nothing
    # is left), the detached work still to settle, and what was spent. The
    # read is `phases`: `progress` is the host's EPHEMERAL feed,
    # `ProgressFrame` below, and one word carries one meaning.
    AgentLoopPhases = Data.define(:phases, :current, :background, :spend) do
      def current_phase = current && phases[current]
    end

    # ONE EPHEMERAL FRAME off a host's `progress` feed (executor.md
    # "Progress"): what an executor posted while its work happened — a
    # `bash` tail under a claim (`executor_progress`: the loop key, the
    # task key, the tool's name), a process's output under the host's
    # binding (`process_output`: the host key and `process_id`) — with the
    # kernel's stamps (`executor_public_id`, `at` to the millisecond) and
    # the payload as an untyped Hash (`text_tail`/`structured`, or
    # `lines`/`exit`). `type` is carried VERBATIM, and `executor_public_id`
    # rides by presence: the kernel's own frames share this feed
    # (`round_started`, `step_started`, `step_claimed` — the last alone
    # names an executor), and a frame this gem predates must reach the
    # caller whole rather than raise. Nothing here is durable and nothing
    # replays — a subscriber sees what follows its subscription.
    ProgressFrame = Data.define(
      :type, :agent_loop_public_id, :conversation_public_id, :task_key, :tool_name, :process_id,
      :executor_public_id, :at, :payload
    ) do
      def executor_progress? = type == "executor_progress"
      def process_output? = type == "process_output"
      # The kernel's own three (agent_loops.md "The event stream"): an
      # attempt dialled (`spine`, `attempt`, `model`, `request_bytes` in
      # the payload), a tool row dispatched, run or held (`status`), and
      # the claimant — the one that names an executor.
      def round_started? = type == "round_started"
      def step_started? = type == "step_started"
      def step_claimed? = type == "step_claimed"
      def text_tail = payload["text_tail"]
      def lines = Array(payload["lines"])
      def to_h = super.compact
    end
  end
end
