require "json"
require "tempfile"
require_relative "process_runner"

module E2E
  # OUT-OF-BAND OPERATOR ACTIONS, performed the way an operator would.
  #
  # A provider lane is refused at selection until somebody enables it
  # (`ModelSelection::Resolver` answers `provider_disabled` on a missing or
  # disabled policy row), and there is no console screen for that yet — the
  # provider-management round owns it. So the harness does what an operator
  # does today: runs the command in the deployment.
  #
  # `bin/rails runner` in the SAME per-run world as the server, so it reads the
  # same databases. It is deliberately narrow: one named action, no arbitrary
  # code from a caller.
  class NexusOperator
    # IDEMPOTENT IN ONE WORLD. The command is a CAS on the policy row: a
    # first call creates it (no version to expect), every later one must
    # carry the row's current `lock_version` or the kernel answers `stale`.
    # A process running several journeys against one server enables the
    # same lane once per journey, so the version is read, not assumed —
    # twelve live journeys once died at the second on a hard-coded nil.
    ENABLE_LANE = <<~RUBY.freeze
      def enable_lane!(provider_id)
        policy = ModelProviderConfig.find_by(account: Account.sole, provider_id: provider_id)
        lane = ModelProviders::EnableLane.call(
          account: Account.sole, provider_id: provider_id, expected_lock_version: policy&.lock_version
        )
        abort("enable_lane failed: \#{lane.outcome}") unless lane.done?
      end
    RUBY

    ENABLE_DEV_LANE = <<~RUBY.freeze
      #{ENABLE_LANE}
      enable_lane!("dev")
    RUBY

    # THE LANE TAKEN AWAY, the same CAS the other way: what a journey needs
    # to make the kernel park a person's head `blocked` (`provider_disabled`
    # at the drain) on a model that is otherwise fine — `rho say` names no
    # model of its own, so an unknown model cannot be its blocked shape.
    DISABLE_DEV_LANE = <<~RUBY.freeze
      policy = ModelProviderConfig.find_by!(account: Account.sole, provider_id: "dev")
      lane = ModelProviders::DisableLane.call(
        account: Account.sole, provider_id: "dev", expected_lock_version: policy.lock_version
      )
      abort("disable_lane failed: \#{lane.outcome}") unless lane.done?
    RUBY

    def initialize(nexus_root:, env:, deadline: nil)
      @nexus_root = nexus_root
      @env = env
      @deadline = deadline
    end

    # CUTTING A CABLE ON PURPOSE, the way the deployment itself does: Action
    # Cable's remote disconnect is what a signed-out session or a rolling
    # restart uses, and it reaches the web process through the same bus the
    # broadcasts do. A journey that wants to prove recovery has to break the
    # socket for real — killing the whole web host would prove something
    # coarser and disturb every other lane sharing it.
    # Action Cable addresses a live connection by EVERY identifier the
    # connection class declares, and this one declares two — so the token is
    # enumerated from the user rather than handed over. That is not only
    # tidier: a raw member secret on a command line is readable by anything
    # that can run `ps`, and this harness redacts secrets precisely so they
    # never reach a diagnostic.
    DISCONNECT_CABLE = <<~RUBY.freeze
      user = User.find_by!(public_id: ARGV.fetch(0))
      tokens = user.access_tokens.where(credential_plane: "member")
      abort("no member credential to disconnect") if tokens.empty?
      # Flush Solid Cable's batched writer before this short process exits,
      # after Rails runner has released its executor.
      at_exit { ActionCable.server.pubsub.shutdown }
      tokens.find_each do |token|
        # Every identifier the connection declares (the executor identity
        # beside the member's, nil on a member cut), or Action Cable refuses.
        ActionCable.server.remote_connections
          .where(current_user: user, current_access_token: token, current_executor_token: nil).disconnect
      end
    RUBY

    # THE CREDENTIAL GOES TO NEXUS, NOT TO THE HARNESS. A provider's key lives
    # in Nexus's own store, which is where the resolver reads it — the catalog
    # fragment only says that this lane answers with an api_key, never which
    # one. There is no console screen for this yet, so the operator does what
    # an operator does today.
    #
    # The value travels on STDIN rather than as an argument, because an
    # argument is readable by anything that can run `ps`.
    SET_PROVIDER_API_KEY = <<~RUBY.freeze
      key = $stdin.read.strip
      abort("no api key on stdin") if key.empty?
      result = ModelProviders::SetAPIKey.call(
        account: Account.sole, provider_id: ARGV.fetch(0), api_key: key
      )
      abort("set_api_key failed: \#{result.outcome}") unless result.done?
      #{ENABLE_LANE}
      enable_lane!(ARGV.fetch(0))
    RUBY

    def enable_dev_lane!
      run(ENABLE_DEV_LANE)
    end

    def disable_dev_lane!
      run(DISABLE_DEV_LANE)
    end

    # THE ACCOUNT'S BILLING UNIT, which nothing in the product writes. Four
    # services READ `Account#cost_unit` and no service sets it, so a fresh
    # account cannot price any paid lane and admission refuses
    # `unresolved_cost` — correctly: a kernel that cannot price work must
    # not spend on it. The dev lane never meets this because it is free.
    def set_cost_unit!(unit)
      run(SET_COST_UNIT, unit)
    end

    SET_COST_UNIT = <<~RUBY.freeze
      account = Account.sole
      account.update!(cost_unit: ARGV.fetch(0))
    RUBY

    def enable_provider!(provider_id, api_key)
      run(SET_PROVIDER_API_KEY, provider_id, stdin: api_key)
    end

    # THE PREPARED VARIANT'S BYTES (the attachments journey's pin): what the kernel puts on the wire
    # for an upload under a model row is its PREPARATION — the Active Storage variant
    # `UploadMedia.prepare` makes for the row's `input_media` facts (the <=N px re-encode) — never
    # the upload's own bytes. Read the way the dispatch reads it, so a journey pins the wire's count
    # against the kernel's own number.
    PREPARED_UPLOAD_BYTES = <<~RUBY.freeze
      upload = ContentUpload.find_by!(public_id: ARGV.fetch(0))
      model_ref = ARGV.fetch(1)
      snapshot = ModelCatalog.current
      profile = ModelCatalog::ProfileBuilder.call(
        model_ref: model_ref, provider: snapshot.providers.fetch(model_ref.split("/", 2).first),
        model: snapshot.models.fetch(model_ref)
      )
      media = ModelRequests::UploadMedia.prepare(upload, profile.input_media)
      puts media.byte_size
    RUBY

    # WHO STAGED AN UPLOAD: the two creator columns of one row, read the way the kernel stores them
    # — exactly one is set. The one new operator read the capture journey needs; a nonexistent id
    # aborts.
    UPLOAD_CREATOR = <<~RUBY.freeze
      upload = ContentUpload.find_by!(public_id: ARGV.fetch(0))
      puts JSON.generate("creating_user_id" => upload.creating_user_id,
        "creating_executor_id" => upload.creating_executor_id)
    RUBY

    def upload_creator!(upload_public_id)
      JSON.parse(read(UPLOAD_CREATOR, upload_public_id))
    end

    def prepared_upload_bytes!(upload_public_id, model_ref)
      Integer(read(PREPARED_UPLOAD_BYTES, upload_public_id, model_ref).strip)
    end

    def disconnect_cable!(user_public_id)
      run(DISCONNECT_CABLE, user_public_id)
    end

    # THE DEADLINE SWEEP, ON DEMAND. `bin/jobs` runs it every minute in
    # e2e (`recurring.yml`), so a journey that proves expiry would
    # otherwise wait on the scheduler's clock — up to a minute per park.
    # This is the sweep's own entry point and nothing more: it finds the
    # overdue parks and settles each under the loop lock by the tool's
    # effect profile, and a park whose deadline has not passed is left
    # standing (`idle`) — so a journey still waits for the deadline first.
    SWEEP_PARK_TIMEOUTS = <<~RUBY.freeze
      result = AgentRuns::Parks::TimeoutSweep.call
      puts "sweep_park_timeouts: expired=\#{result[:expired]} scanned=\#{result[:scanned]}"
    RUBY

    def sweep_park_timeouts!
      run(SWEEP_PARK_TIMEOUTS)
    end

    # BACKDATING A PARK, so the sweep above finds it overdue NOW. The
    # unit suites' own `expire!` — the park's clock is `await_started_at`
    # plus its effective timeout, and the sweep re-derives every row in
    # Ruby under the loop lock — lifted to the operator for the one
    # journey whose park is two minutes long (the delegate summarizer's
    # announced `TIMEOUT_MS`): the expiry journey already proved the real
    # clock on a thirty-second park, and this one proves what follows the
    # expiry, not the wait. One named row, never a range.
    EXPIRE_PARK = <<~RUBY.freeze
      moved = AgentRunTask.joins(:agent_run)
        .where(agent_runs: { public_id: ARGV.fetch(0) }, node_key: ARGV.fetch(1))
        .update_all(await_started_at: 2.hours.ago)
      abort("expire_park: no park \#{ARGV.fetch(1)} on loop \#{ARGV.fetch(0)}") unless moved == 1
      puts "expire_park: loop=\#{ARGV.fetch(0)} task=\#{ARGV.fetch(1)} backdated=\#{moved}"
    RUBY

    def expire_park!(run_public_id, task_key)
      run(EXPIRE_PARK, run_public_id, task_key)
    end

    # THE ROW COUNTS A FRAME MUST NOT MOVE: the primary's three tables a loop's work writes, and the
    # cable adapter's own message table — `solid_cable` in the e2e world's development env, where
    # every broadcast is a row. One read, both databases, as JSON; a journey compares two of them
    # across a window in which only frames flowed. `SolidCable::Message` connects to the cable
    # database by its own `connects_to`, so the count is the cable's, never the primary's.
    TABLE_COUNTS = <<~RUBY.freeze
      puts JSON.generate({
        "agent_run_tasks" => AgentRunTask.count,
        "conversation_event_items" => ConversationEventItem.count,
        "content_bodies" => ContentBody.count,
        "solid_cable_messages" => SolidCable::Message.count,
      })
    RUBY

    def table_counts!
      JSON.parse(read(TABLE_COUNTS).lines.last.to_s)
    end

    # REVOKING A MACHINE'S REGISTRATION: a KILLed process leaves a LIVE address — nothing about a
    # dead process changes `eligible_for?` — so its rows still dispatch to it and park until the
    # sweep. `tool_not_served` at start is what a REVOKED provider earns, and the console has no
    # screen for it yet, so the harness does what an operator does. Idempotent: `revoke` is a no-op
    # on a revoked row.
    REVOKE_EXECUTOR = <<~RUBY.freeze
      executor = TaskExecutor.find_by!(public_id: ARGV.fetch(0))
      executor.revoke
      puts "revoke_executor: executor=\#{executor.public_id} status=\#{executor.reload.status}"
    RUBY

    def revoke_executor!(executor_public_id)
      run(REVOKE_EXECUTOR, executor_public_id)
    end

    # THE RECEIPTS OF ONE CONVERSATION with the wire's cache breakdown
    # (the 1-hour tier's paid observation, L437): the public usage shape
    # carries the persisted six counters and never the per-tier write
    # share, which settlement alone reads off `provider_usage`
    # (`cache_creation.ephemeral_{5m,1h}_input_tokens`) — so the harness
    # reads the rows the way settlement does. Every invocation the
    # conversation hosted: its direct replies on its own id and every
    # round of its loop-backed turns, in recording order.
    USAGE_RECEIPTS = <<~RUBY.freeze
      conversation = Conversation.find_by!(public_id: ARGV.fetch(0))
      loops = AgentRun.joins(conversation_turn_variant: :conversation_turn)
        .where(conversation_turns: { conversation_id: conversation.id })
      invocations = ModelInvocation.where(conversation_id: conversation.id)
        .or(ModelInvocation.where(agent_run_id: loops.select(:id)))
      by_public_id = invocations.index_by(&:public_id)
      rows = UsageRecord.where(model_invocation_public_id: by_public_id.keys).order(:recorded_at, :id).map do |record|
        creation = Hash(record.provider_usage).fetch("cache_creation", {})
        {
          "usage_record_public_id" => record.public_id,
          "run_public_id" => by_public_id.fetch(record.model_invocation_public_id).agent_run&.public_id,
          "attempt_ordinal" => record.attempt_ordinal, "status" => record.status,
          "input_tokens" => record.input_tokens, "cache_read_tokens" => record.cache_read_tokens,
          "cache_creation_tokens" => record.cache_creation_tokens,
          "cache_creation_5m_tokens" => creation["ephemeral_5m_input_tokens"],
          "cache_creation_1h_tokens" => creation["ephemeral_1h_input_tokens"],
        }
      end
      puts JSON.generate(rows)
    RUBY

    def usage_receipts!(conversation_public_id)
      JSON.parse(read(USAGE_RECEIPTS, conversation_public_id).lines.last.to_s)
    end

    # Rebuild accepted requests with the current isolated catalog, without a
    # credential or provider IO. This explains wire/cache measurements; public
    # task and result APIs remain the journey's behavior assertions.
    COMPILED_REQUESTS = <<~RUBY.freeze
      run = AgentRun.find_by!(public_id: ARGV.fetch(0))
      rows = run.agent_run_tasks.where.not(selected_model_invocation_id: nil).order(:id).map do |task|
        invocation = ModelInvocation.find(task.selected_model_invocation_id)
        catalog = ModelSelection::Resolver.effective_provider_catalog(
          invocation.account, ModelCatalog.current, invocation.provider_id)
        ref = "\#{invocation.provider_id}/\#{invocation.model_ref}"
        entry = catalog.models.fetch(ref)
        profile = ModelCatalog::ProfileBuilder.call(model_ref: ref,
          provider: catalog.providers.fetch(invocation.provider_id), model: entry)
        compiled = ModelRequests::Build.call(invocation: invocation, profile: profile,
          base_url: ModelCatalog.provider_base_url(invocation.provider_id, snapshot: catalog),
          host: "model_runner", reasoning_context: entry.dig("capabilities", "reasoning", "default_context"))
        receipts = UsageRecord.where(model_invocation_public_id: invocation.public_id).order(:attempt_ordinal).map do |record|
          record.attributes.slice("attempt_ordinal", "status", "input_tokens", "output_tokens", "reasoning_tokens",
            "cache_read_tokens", "cache_creation_tokens", "cost_unit", "cost_amount", "duration_ms", "time_to_first_token_ms")
        end
        { "task_key" => task.node_key, "model" => ref, "api_format" => profile.adapter_profile,
          "refusal" => compiled.refusal, "payload" => (JSON.parse(compiled.request.payload) if compiled.built?),
          "receipts" => receipts }
      end
      puts JSON.generate(rows)
    RUBY

    def compiled_requests!(run_public_id)
      JSON.parse(read(COMPILED_REQUESTS, run_public_id).lines.last.to_s)
    end

    private

      # A named action whose stdout is the answer.
      def read(script, *arguments)
        Tempfile.create("nexus-operator-read") do |out|
          run(script, *arguments, out: out)
          out.rewind
          out.read.to_s.force_encoding(Encoding::UTF_8)
        end
      end

      def run(script, *arguments, stdin: nil, out: $stdout)
        status = ProcessRunner.run(
          File.join(@nexus_root, "bin", "rails"), "runner", script, *arguments,
          env: @env, chdir: @nexus_root, deadline: @deadline, stdin: stdin, out: out
        )
        raise "operator action failed with status #{status.exitstatus.inspect}" unless status.success?

        status
      end
  end
end
