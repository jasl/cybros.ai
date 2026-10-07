require_relative "agent_membership_test_helper"

# Deadlocks are prevented by one global acquisition order, not review intuition. This is that order
# made mechanical: the SQL stream of each driven flow is captured, its explicit row locks are
# grouped into their owning transactions by savepoint depth, and every transaction must acquire
# tables in ladder order. A table that starts taking explicit locks without being placed on the
# ladder fails loudly — joining the order is a deliberate act, and the Task/conversation lanes
# extend this ladder rather than starting from intuition.
#
# What the ladder can and cannot see, honestly: it pins the TABLE-level order from the SQL text
# (`FOR UPDATE`, `FOR NO KEY UPDATE`, `FOR SHARE`, or `FOR KEY SHARE`). The within-table edges — the
# mapped Agent before the connecting human, humans by ascending id — live in row values the SQL
# stream does not carry; they stay pinned by the comments at each lock site and by the race tests
# beside them (rotate_test's ABBA deadlock test is the canonical one). M0 pre-ranks every model-work
# table that actually takes explicit locks; each physical slice adds its real driven flow. Immutable
# or currently unlocked tables stay absent so a later explicit lock still fails loudly. A locking
# `OF` clause naming more than one relation fails rather than pretending simultaneous acquisition
# has a sequential order; the sanctioned admission join names exactly one. Implicit FK KEY SHARE
# edges remain a schema/writer audit because PostgreSQL does not expose them as locking SELECT
# statements. Flows are driven single-threaded here, so the notification stream is this connection's
# own.
module LockOrderTestHelper
  extend ActiveSupport::Concern

  include AgentMembershipTestHelper
  include ActiveJob::TestHelper
  include InvocationHarness
  include RunLaneTestHelper
  include RunSeamTestHelper

  included do
    setup do
      # The dev lane's enablement writes policy/catalog rows; keep it out of
      # every captured flow so the guard sees only the flow's own locks.
      DevModelLane.ensure_enabled!
    end
  end

  # The model-work aggregates lock below Workspace/User authority rows. A conversation lock
  # serializes lifecycle, fork, and reaping before its loop and invocation work are locked.
  # Conversation inputs follow the host and loop: host -> loop -> inputs has no reverse edge.
  # Default Runner selection writes only the host preference and its event under the host lock;
  # accepted tasks keep their targets, so this operation acquires no task locks.
  #
  # Upload rows follow agent_runs and precede conversation_inputs. Each write pins resolved
  # uploads FOR KEY SHARE before locking the row that binds them: a InferenceRequest creation holds
  # workspace -> user, a conversation write holds its host, and loop append holds its loop.
  # The content writer subsequently takes the same lock on fragments. The orphan reaper destroys
  # unlocked uploads and holds no other aggregate lock.
  #
  # model_provider_runtime_states has an implicit lock outside this SELECT-based detector:
  # INSERT ... ON CONFLICT DO UPDATE holds the conflicting row until commit. ApplyResult writes
  # it last, after its invocation and usage rows. Any additional writer must preserve that order;
  # the absence of a locking SELECT does not make the implicit lock disappear.
  MODEL_WORK_LOCK_LADDER = %w[
    model_provider_configs
    model_provider_oauth_sessions
    model_provider_oauth_tasks
    model_provider_credentials
    inference_requests
    conversations
    agent_runs
    content_uploads
    conversation_inputs
    agent_run_tasks
    model_invocations
    content_bodies
    content_fragments
    usage_budgets
    inference_request_event_cursors
    conversation_event_cursors
  ].freeze

  # `identities` precedes `users` (Identity session verification locks the identity, then the user —
  # identity.rb). `device_authorizations` precedes `users` (Connect locks the Request row, then the
  # mapped agent, then the connector). The two heads never co-occur in one transaction today; their
  # relative rank is fixed here so the first flow that combines them has an answer instead of a
  # choice. `workspaces` precedes `users` for every flow that takes both; Workspace create has no
  # Workspace row and starts at `users`. `usage_records` heads the whole ladder, and the reason is
  # the settle batch's shape (Stage 4 item 3): the scan IS the discovery — SettleSpend selects its
  # receipt frontier FOR UPDATE SKIP LOCKED before it can know which payers it must lock, so the
  # receipt rows are necessarily acquired above every principal. SKIP LOCKED means no writer ever
  # WAITS on a receipt lock, so the head position cannot complete a cycle; ranking it anyway keeps
  # the guard's rule mechanical — a table that takes explicit locks has a deliberate place, never an
  # improvised one.
  FOUNDATION_LOCK_LADDER = %w[
    usage_records
    identities
    device_authorizations
    workspaces
    users
    task_executors
    refresh_token_families
    refresh_tokens
  ].freeze

  LOCK_LADDER = (FOUNDATION_LOCK_LADDER + MODEL_WORK_LOCK_LADDER).each_with_index.to_h.freeze

  private

    def create_invocation(
      account: accounts(:cybros), workspace: workspaces(:shared), creator: users(:member),
      workload: "text_generation", model: nil, input: nil, status: nil
    )
      selection = DevModelLane.selection(
        workload: workload, account: account, **(model ? { model: model } : {})
      )
      inference_request = InferenceRequest.create!(
        account: account, workspace: workspace, creating_user: creator,
        workload: selection.workload
      )
      source = if input
        ContentBodies::Replace.call(
          owner: inference_request, role: InferenceRequests::Create::BODY_ROLE,
          entries: Nexus::InputEntries.for(input), seal: true
        ).body
      end
      invocation = DevModelLane.create_invocation!(inference_request: inference_request, selection: selection)
      ContentBodies::CloneSealed.call(source: source, owner: invocation, role: "request") if source
      invocation.update!(status: status) if status
      [inference_request, invocation]
    end

    # A started loop with one running model step, built through the real
    # doors so the flow under test is the production one.
    def create_agent_run_task(account:, creator:)
      workspace = workspaces(:shared)
      created = create_loop(model("step", "prompt" => "go"), workspace: workspace, creating_user: creator)
      raise "loop create refused: #{created.outcome}" unless created.created?

      agent_run = created.agent_run
      AgentRuns::Start.call(AgentRuns::Start::Command.new(
        agent_run: agent_run, acting_user: creator
      ))
      AgentRuns::ScheduleReady.call(agent_run_id: agent_run.id)
      [agent_run, agent_run.agent_run_tasks.sole.reload]
    end

    def create_content_upload(account:)
      bytes = "lock-order-upload-#{SecureRandom.hex(4)}"
      account.content_uploads.create!(
        creating_user: users(:member),
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "lock-order.png", content_type: "image/png"
        )
      )
    end

    # Explicit locking reads, grouped by savepoint depth into their owning
    # transactions. Under transactional tests every application transaction is
    # a savepoint on the fixture wrapper, so depth 0 -> 1 opens a transaction
    # and the release back to 0 closes it; a lock outside any savepoint rides
    # the wrapper and joins an ambient sequence, which only over-constrains.
    def capture_lock_sequences
      sequences = []
      current = nil
      depth = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql].to_s
        if sql.start_with?("SAVEPOINT")
          depth += 1
          current = (sequences << []).last if depth == 1
        elsif sql.start_with?("RELEASE SAVEPOINT", "ROLLBACK TO SAVEPOINT")
          depth = [depth - 1, 0].max
          current = nil if depth.zero?
        elsif sql.match?(/FOR (?:(?:NO KEY )?UPDATE|(?:KEY )?SHARE)/)
          of_targets = sql[
            /FOR (?:(?:NO KEY )?UPDATE|(?:KEY )?SHARE) OF (.+?)(?: NOWAIT| SKIP LOCKED)?\s*\z/,
            1
          ]
          if of_targets&.include?(",")
            flunk "locking OF must name exactly one relation — review multi-relation locks explicitly"
          end

          # `OF` names what is actually locked, and the plan mandates that
          # form for the one sanctioned locking join (admission's
          # `FOR UPDATE OF model_invocations SKIP LOCKED`); reading the first
          # FROM relation instead would file that lock under the queue entry.
          table = locked_table(sql)
          if table
            current ||= (sequences << []).last
            current << table
          end
        end
      end
      yield
      sequences.reject(&:empty?)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def locked_table(sql)
      locking_clause = /FOR (?:(?:NO KEY )?UPDATE|(?:KEY )?SHARE)/
      of_match = sql.match(
        /#{locking_clause.source} OF (?:(?:"[^"]+")\.)?"?(?<table>[a-z_][a-z0-9_]*)"?/
      )
      return of_match[:table] unless of_match.nil?

      sql.match(
        /\bFROM\s+(?:(?:"[^"]+")\.)?"(?<table>[a-z_][a-z0-9_]*)"/
      )&.[](:table)
    end

    def violations_in(sequences)
      sequences.filter_map do |sequence|
        ranks = sequence.map do |table|
          LOCK_LADDER.fetch(table) do
            flunk "#{table} takes explicit row locks but is not on the ladder — " \
                  "place the new table deliberately in the lock order, do not let it join by accident"
          end
        end
        sequence.join(" → ") if ranks.each_cons(2).any? { |a, b| b < a }
      end
    end

    def assert_ladder_order(flow)
      sequences = capture_lock_sequences { yield }
      assert_not_empty sequences, "#{flow} acquired no explicit row locks — the guard saw nothing"
      violations = violations_in(sequences)
      assert_empty violations, "#{flow} acquired locks against the ladder:\n  #{violations.join("\n  ")}"
      sequences
    end

    # The credential fixture rotate_test mints, replicated: a family with one
    # live rotating pair, built the way Consume leaves it.
    def mint_family(member:, executor:)
      family = RefreshTokenFamily.create!(
        account: member.account,
        user: member,
        access_token_name: "Device pairing",
        task_executor: executor,
        credential_epoch: executor.credential_epoch,
        user_authority_generation: member.authority_generation,
        last_used_at: Time.current
      )
      access = member.access_tokens.create!(
        refresh_token_family: family,
        credential_plane: :executor_transport,
        name: "Device pairing", source: :oauth_device,
        lookup_id: SecureRandom.base58(24), secret_digest: "seed",
        expires_at: AccessToken::OAUTH_TTL.from_now, task_executor: executor,
        credential_epoch: executor.credential_epoch,
        user_authority_generation: member.authority_generation
      )
      RefreshTokens::Issue.call(refresh_token_family: family, access_token: access)
    end
end
