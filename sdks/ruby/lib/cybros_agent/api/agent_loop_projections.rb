module CybrosAgent
  module Api
    # The runner boundary's wire grammar, read strictly where the server
    # guarantees a member and leniently where it compacts one away.
    #
    # THE AUTHOR HALF READS LENIENTLY, because the trace COMPACTS: the
    # presenter builds every projection with `.compact`, so an absent
    # member means "no value" and never "the server forgot" — a task with
    # no retry budget carries no `retry` key at all. Reading those strictly
    # would make an ordinary task unparseable.
    module AgentLoopProjections
      include WorkspaceProjections
      include EventProjections
      # The waiting room's shape is the conversation's, hosted.
      include ConversationProjections

      # Nil when nothing names a role: the presenter compacts an absent
      # address to nothing, and a pool row may name a role
      # alone or an empty address.
      ADDRESSED_TO = lambda do |hash|
        address = optional_hash(hash, "addressed_to")
        shape(AddressedTo, address) unless address.nil? || address["role"].nil?
      end

      SHAPES = {
        InboxTask => {
          # The kernel writes a kind on every row it lists or grants. A
          # String rather than a closed set, because a word this gem
          # predates must be carried to the runner, never refused.
          kind: :string,
          agent_loop_public_id: :string,
          workspace_public_id: :string,
          # STATED ON EVERY ROW, never compacted: the kernel merges both
          # after its compaction, so a row without the key breaks the
          # contract. An explicit null on a standalone loop's row.
          conversation_public_id: :nullable_string,
          # The conversation's parent on a spawned child's row; an explicit
          # null on a root's and a standalone loop's.
          parent_public_id: :nullable_string,
          task_key: :string,
          # An ask row names no tool and carries its question instead —
          # and its choices as data, when it gave them.
          prompt: :optional_string,
          options: :optional_string_list,
          multi: :optional_boolean,
          tool_name: :optional_string,
          # The model's own spelling when the profile declared an alias of
          # a kernel tool; compacted away on a plain call, and nil here.
          tool_alias: :optional_string,
          # COMPACTED WHEN EMPTY, never absent in meaning: a tool called
          # with no arguments reads as {} rather than nil, so a runner
          # never has to distinguish "no arguments" from "not told".
          tool_input: :json_object_or_empty,
          # The kernel's stamp on an overridden row, absent on every other:
          # an opaque frozen map when present, nil when not — never {}.
          scope: :optional_json_object,
          tool_call_id: :optional_string,
          started_at: :optional_string,
          deadline_at: :optional_string,
          # The park's budget the deadline was cut from. The kernel states
          # it on every parked row; present-or-nil like the two stamps
          # beside it, and a budget that is not an integer is malformed.
          timeout_ms: :optional_integer,
          claimed: :flag,
          addressed_to: ADDRESSED_TO,
          # The frozen profile an APPROVAL row carries for its approver;
          # absent on a runner row, and nil here — never {}.
          effect_profile: :optional_json_object,
        },
        AddressedTo => {
          role: :string,
          executor_public_id: :optional_string,
          presence: :optional_string,
          last_seen_at: :optional_string,
        },
        # Nil until somebody took the row.
        ClaimedBy => { executor_public_id: :string },
        AgentLoop => {
          public_id: :string,
          status: :string,
          failure_reason: :optional_string,
          deliverable_task_key: :optional_string,
          # ABSENT ON A LISTING, by design: `basic` is the index shape and
          # carries no tasks. An empty list is the honest reading — a
          # caller that wants them fetches the loop.
          tasks: [:shapes_or_empty, LoopTask],
          # Absent buckets read zero, so a kernel that grows a status the
          # gem predates degrades to "not counted here" rather than raising.
          task_progress: [:shape_or_empty, LoopProgress],
          # Absent is the ordinary case — a loop that needs nothing from
          # anybody answers no attention block at all.
          attention: [:optional_shape, LoopAttention],
          turn: [:optional_shape, LoopTurn],
          # A standalone loop's own waiting room; absent on a loop-backed
          # loop, whose queue is its conversation's, and on a listing.
          input_queue: [:optional_shape, ConversationInputQueue],
          started_at: :optional_string,
          paused_at: :optional_string,
          completed_at: :optional_string,
          details_pruned_at: :optional_string,
          created_at: :optional_string,
          updated_at: :optional_string,
          # Where this loop's runner-kind calls land; the loop
          # document compacts it away when unbound.
          runner: [:optional_shape, RunnerBinding],
          # The effective mechanism word: explicit null on a
          # standalone loop, absent on a listing — nil either way.
          prompt_mechanism: :optional_string,
          approval_mode: :optional_string,
        },
        LoopTask => {
          key: :string,
          kind: :string,
          status: :string,
          lifetime: :string,
          wake: :string,
          after: :names,
          waiting_on: :names,
          on_failure: :optional_string,
          failure_resolution: :optional_string,
          # `retry` is `{budget: N}` when there is one and absent when
          # there is not; flattening it here keeps the zero case a zero
          # rather than a nil the caller has to test for.
          retry_budget: ->(hash) { (optional_hash(hash, "retry") || {})["budget"].to_i },
          tool_name: :optional_string,
          # An outcome SUMMARY object, not the output — and never a string,
          # which is what this asked for until a real completed loop
          # refused to parse.
          result: :optional_json_object,
          # The typed refusal, kept as a map: its `key` is a closed
          # vocabulary the kernel owns and grows, and a client that
          # predates a new member must read it rather than fail on it.
          error: :optional_json_object,
          visibility: :optional_string,
          created_at: :optional_string,
          started_at: :optional_string,
          completed_at: :optional_string,
          # Served per round and once dropped: which lane it ran on.
          model: :optional_json_object,
          mailed_at: :optional_string,
          addressed_to: ADDRESSED_TO,
          claimed_by: [:optional_shape, ClaimedBy],
          # The stage's fact, compacted away until a decision.
          approval: :json,
        },
        LoopProgress => LoopProgress.members.to_h { |member| [member, :count] },
        LoopAttention => { reason: :string, blocked_task_keys: :names, blocked_task_overflow: :raw },
        LoopTaskDetail => {
          task: ->(hash) { shape(LoopTask, hash) },
          declaring_task_key: :optional_string,
          output: :optional_string,
          output_preview: :optional_string,
          content: :raw,
          structured_content: :raw,
          prompt: :optional_string,
          options: :optional_string_list,
          multi: :optional_boolean,
          # WHAT A TOOL CALL WAS ASKED TO RUN. Served on this read only —
          # the trace stays a task list — and a reader with no arguments
          # cannot render a call at all.
          tool_input: :optional_json_object,
          request_bytes: :optional_integer,
          instructions: :optional_string,
          tool_definitions: :optional_json_array,
          # The UI's two fields, present only when the executor sent them.
          title: :optional_string,
          metadata: :optional_json_object,
          wait: :optional_json_object,
        },
        # The manual compaction door: 202 with the repaired round and the
        # summarizer it authored.
        CompactedRound => { task: [:shape, LoopTask], summary_task_key: :string },
        # Read off the receipt. THE REPLAY ANSWERS THE ORIGINAL RESPONSE,
        # status included, and marks itself in the receipt — so the flag
        # is read from the body rather than inferred from a status that
        # was chosen by the call this one is repeating.
        AppendedTasks => {
          accepted_task_keys: :names,
          steps: :json_array_or_empty,
          deliverable_task_key: :optional_string,
          revision: :raw,
          resolution_tokens: :json_object_or_empty,
          replayed: :flag,
        },
        # The turn shape beside the loop's row: the two ids ride
        # only on a loop-backed loop, the reason only while it stands.
        LoopTurn => {
          status: :string,
          failure_reason_key: :optional_string,
          public_id: :optional_string,
          conversation_public_id: :optional_string,
          answering_user_public_id: :optional_string,
          model: :optional_json_object,
        },
        # The thread's rows, typed where the kernel guarantees a member
        # (`agent_loops.json#/thread_row_projection_required`) and by
        # presence elsewhere; `usage`, `error` and `metadata` stay the
        # maps the wire carries.
        AgentLoopTranscript => {
          rounds: [:shapes, ThreadRow],
          next_before: [:raw, "pagination", "next_before"],
          has_older: [:flag, "pagination", "has_older"],
        },
        ThreadRow => {
          task_key: :string,
          spine: :boolean,
          status: :string,
          visibility: :string,
          text_preview: :optional_string,
          text_bytes: :optional_integer,
          usage: :optional_json_object,
          error: :optional_json_object,
          compacted_before: :optional_string,
          pruned_before: :optional_string,
          started_at: :optional_string,
          completed_at: :optional_string,
          calls: [:shape, ThreadCalls],
          branches: :string_list,
        },
        ThreadCalls => { count: :integer, items: [:shapes, ThreadCall] },
        ThreadCall => {
          task_key: :string,
          tool_call_id: :optional_string,
          name: :string,
          tool: :optional_string,
          status: :string,
          is_error: :optional_boolean,
          title: :optional_string,
          metadata: :optional_json_object,
          output_preview: :optional_string,
          output_bytes: :optional_integer,
          started_at: :optional_string,
          completed_at: :optional_string,
        },
        # The picture reads strictly where the kernel guarantees a member
        # and carries `status`/`kind` verbatim; `join` and `error_key` are
        # absent on every node that has none.
        AgentLoopGraph => { nodes: [:shapes, GraphNode], edges: [:shapes, GraphEdge], mermaid: :string },
        GraphNode => {
          key: :string,
          kind: :string,
          status: :string,
          visibility: :string,
          deliverable: :boolean,
          lifetime: :string,
          wake: :string,
          input_from: :string_list,
          result_from: :string_list,
          spine: :optional_boolean,
          error_key: :optional_string,
          join: :optional_json_object,
          expansion_parent: :optional_string,
        },
        GraphEdge => { from: :string, to: :string, structural: :boolean },
        AgentLoopPhases => {
          phases: [:shapes, LoopPhase],
          current: :raw,
          background: [:shapes, BackgroundTask],
          spend: :json_object_or_empty,
        },
        LoopPhase => { label: :string, keys: :string_list, done: :count, total: :count, status: :string },
        BackgroundTask => { key: :string, status: :string, mailed_at: :optional_string },
        ClaimedTask => {
          task: [:shape, InboxTask],
          claim_token: [:string, "claim", "claim_token"],
          deadline_at: [:optional_string, "claim", "deadline_at"],
        },
        ClaimStatus => { active: [:boolean, "claim", "active"] },
      }.freeze
    end
  end
end
