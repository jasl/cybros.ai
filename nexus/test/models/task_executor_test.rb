require "test_helper"

class TaskExecutorTest < ActiveSupport::TestCase
  setup do
    @executor = task_executors(:address)
    @agent = users(:agent)
    @owner = users(:owner)
  end

  test "the address fixture is valid" do
    assert_predicate @executor, :valid?
    assert_equal @executor, TaskExecutor.address_for(@agent)
  end

  test "an agent_application's profile must be a non-system agent member" do
    %i[member system].each do |target|
      executor = TaskExecutor.new(
        account: @agent.account, agent: users(target),
        executor_kind: :agent_application, display_name: "Bad actor"
      )
      assert_not executor.valid?
      assert executor.errors.of_kind?(:agent, :not_agent_member)
    end
  end

  test "creating an agent_application requires an active agent with an active steward" do
    @agent.remove
    executor = @agent.reload.task_executors.new(
      account: @agent.account, executor_kind: :agent_application, display_name: "R"
    )
    assert_not executor.valid?
    assert executor.errors.of_kind?(:agent, :not_eligible)
  end

  test "creating an agent_application rejects a restored Profile with unapplied steward shutdown" do
    steward = users(:member)
    profile = create_agent_member(
      steward: steward,
      agent_identifier: "pending-profile-executor"
    )
    assert_equal :removed, steward.remove
    assert_equal :restored, steward.restore

    executor = profile.task_executors.new(
      account: profile.account,
      executor_kind: :agent_application,
      display_name: "Must wait"
    )

    assert_not executor.valid?
    assert executor.errors.of_kind?(:agent, :not_eligible)
  end

  # An Agent is single-instance. The database, not the service, is what makes that true: a second
  # live address for one profile has to be impossible even when two ceremonies race.
  test "D24 admits exactly one live address per agent member" do
    second = @agent.task_executors.new(
      account: @agent.account, executor_kind: :agent_application, display_name: "Second"
    )
    assert_not second.valid?
    assert second.errors.of_kind?(:agent_id, :taken)

    assert_raises ActiveRecord::RecordNotUnique do
      second.save!(validate: false)
    end
  end

  # Revoked rows are outside the predicate so the history a profile
  # accumulates never blocks its next connection.
  test "a revoked address does not block the profile's next one" do
    assert_equal :revoked, @executor.revoke
    second = @agent.task_executors.create!(
      account: @agent.account, executor_kind: :agent_application, display_name: "Second"
    )

    assert_equal second, TaskExecutor.address_for(@agent)
  end

  # Current-epoch successful-contact history is product information: nothing in the delivery path
  # may read it, and it never claims the process is running now.
  test "an executor is not seen until its credential authenticates" do
    assert_nil @executor.last_seen_at

    minted = create_bound_credential(executor: @executor, name: "Device")
    assert_not_nil AccessToken.authenticate_executor_token(minted.secret)

    assert_not_nil @executor.reload.last_seen_at
  end

  # A write on a read is only safe because it is sampled. The assertion that
  # matters is the ABSENCE of the second write, not the presence of the first.
  test "a burst of authentications costs one stamp per window" do
    minted = create_bound_credential(executor: @executor, name: "Device")
    AccessToken.authenticate_executor_token(minted.secret)
    first = @executor.reload.last_seen_at

    5.times { AccessToken.authenticate_executor_token(minted.secret) }
    assert_equal first, @executor.reload.last_seen_at

    # Past the window, the next one lands.
    @executor.update_columns(last_seen_at: first - TaskExecutor::LAST_SEEN_REFRESH_RATE - 1.minute)
    AccessToken.authenticate_executor_token(minted.secret)
    assert_operator @executor.reload.last_seen_at, :>, first
  end

  # The two stamps answer different questions and are deliberately different
  # columns: a contact sample that moved the credential's cutoff would extend
  # the inactivity window that decides when a lineage lapses.
  test "seeing an executor never extends its credential's inactivity window" do
    minted = create_bound_credential(executor: @executor, name: "Device")
    family = minted.token.refresh_token_family
    family.update_columns(last_used_at: 20.days.ago)
    before = family.reload.last_used_at

    @executor.refresh_last_seen_at(expected_epoch: @executor.credential_epoch)

    assert_not_nil @executor.reload.last_seen_at
    assert_equal before, family.reload.last_used_at
  end

  # A member-plane credential is not an executor being seen: it authenticates
  # the profile, and the address may be somewhere else entirely.
  test "member-plane authentication does not stamp an address" do
    minted = create_bound_credential(executor: @executor, name: "Device")

    # The same secret refused on the other plane: a member call is the profile
    # authenticating, and the address may be somewhere else entirely.
    assert_nil AccessToken.authenticate_token(minted.secret)
    assert_nil @executor.reload.last_seen_at
  end

  test "a profile with no live address resolves to nothing rather than failing" do
    @executor.revoke

    assert_nil TaskExecutor.address_for(@agent)
  end

  # The machine shape: a runner and a tools provider are both a manager Human's, an identifier and a
  # scope — never an agent's record.
  test "machines of both kinds are outside the D24 rule and belong to a human, not the agent" do
    %i[runner tool_provider].each_with_index do |kind, i|
      machine = @agent.account.task_executors.create!(
        executor_kind: kind, display_name: "Machine #{i}",
        registration_identifier: "install-#{i}", manager: @owner,
        assignment_scope: :user_private
      )
      assert_predicate machine, :machine?
      assert_equal @owner, machine.controlling_human
      assert_equal @owner.managed_resource_shutdown_generation, machine.applied_human_shutdown_generation,
        "the manager's shutdown generation is frozen at creation for both kinds"
    end
    assert_equal 2, @owner.managed_executors.count
    assert_equal 0, @agent.task_executors.where(executor_kind: TaskExecutor::MACHINE_KINDS).count
  end

  test "machine? names the two kinds a Human manages" do
    assert_predicate TaskExecutor.new(executor_kind: :runner), :machine?
    assert_predicate TaskExecutor.new(executor_kind: :tool_provider), :machine?
    assert_not_predicate TaskExecutor.new(executor_kind: :agent_application), :machine?
    assert_equal %w[runner tool_provider], TaskExecutor::MACHINE_KINDS
  end

  test "a tools provider's manager must be an active human member, as a runner's must" do
    assert_equal :removed, users(:member).remove
    provider = @agent.account.task_executors.new(
      executor_kind: :tool_provider, display_name: "Provider", registration_identifier: "p",
      manager: users(:member).reload, assignment_scope: :user_private
    )

    assert_not provider.valid?
    assert provider.errors.of_kind?(:manager, :not_eligible)
  end

  # The registration key is kind-blind on disk (the live-identity index
  # names both kinds): a manager cannot hold a runner and a provider, or
  # two providers, under one identifier at the same time.
  test "one live machine address per key across both kinds" do
    @agent.account.task_executors.create!(
      executor_kind: :tool_provider, display_name: "Provider", registration_identifier: "shared-key",
      manager: @owner, assignment_scope: :user_private
    )
    %i[tool_provider runner].each do |kind|
      duplicate = @agent.account.task_executors.new(
        executor_kind: kind, display_name: "Again", registration_identifier: "shared-key",
        manager: @owner, assignment_scope: :account_wide
      )
      assert_not duplicate.valid?, kind
      assert duplicate.errors.of_kind?(:registration_identifier, :taken), kind
    end
  end

  test "revocation is terminal and idempotent" do
    assert_equal :revoked, @executor.revoke
    assert_equal :revoked, @executor.reload.revoke
    assert_predicate @executor, :revoked?
  end

  test "a consume-style epoch advance fences older epochs" do
    # There is no external epoch-management command: only a winning reconnect consume moves the
    # epoch, in one guarded update.
    advance_credential_epoch(@executor)

    @executor.reload
    assert_predicate @executor, :active?
    assert_equal 2, @executor.credential_epoch
    assert_not @executor.transport_authorized_at?(1)
    assert @executor.transport_authorized_at?(2)
  end

  test "re-pairing preserves the address and lifecycle while advancing its epoch" do
    public_id = @executor.public_id
    @executor.update!(last_seen_at: 1.minute.ago)

    assert_equal @executor, @executor.re_pair(display_name: "Replacement device")

    @executor.reload
    assert_equal public_id, @executor.public_id
    assert_equal "Replacement device", @executor.display_name
    assert_equal 2, @executor.credential_epoch
    assert_nil @executor.last_seen_at,
      "the replacement epoch has not contacted Nexus yet"
    assert_predicate @executor, :active?
  end

  test "an old epoch cannot stamp contact after a replacement clears the sample" do
    minted = create_bound_credential(executor: @executor, name: "Old device")
    stale_executor = TaskExecutor.find(@executor.id)
    assert minted.token.executor_usable?

    TaskExecutor.find(@executor.id).re_pair(display_name: "New device")
    stale_executor.refresh_last_seen_at(
      expected_epoch: minted.token.credential_epoch
    )

    assert_nil @executor.reload.last_seen_at
  end

  # PRESENCE MARKS (r-modes M4): written at the executor socket's edges and
  # never a gate. `mark_connected` is a whole replacement; `clear_connected` clears
  # only when the stored id is the caller's — the reconnect-overlap rule.
  test "mark_connected marks the row whole and clear_connected clears only its own mark" do
    @executor.mark_connected("conn-a")
    @executor.reload
    assert_equal "conn-a", @executor.presence_connection_id
    assert_equal NexusServer.boot_id, @executor.presence_server_id, "the mark names the process that wrote it"
    assert_not_nil @executor.connected_at

    @executor.mark_connected("conn-b")
    assert_equal "conn-b", @executor.reload.presence_connection_id, "a newer connection overwrites"

    @executor.clear_connected("conn-a")
    assert_equal "conn-b", @executor.reload.presence_connection_id, "an older close changes nothing"

    @executor.clear_connected("conn-b")
    assert_marks_cleared @executor
  end

  test "every epoch advance and the terminal revoke clear the presence marks" do
    manager = users(:member)
    runner = manager.managed_executors.create!(
      account: manager.account, executor_kind: :runner, display_name: "Runner",
      registration_identifier: "presence-runner", assignment_scope: :user_private
    )
    stale_applied = runner.applied_human_shutdown_generation

    @executor.mark_connected("conn-1")
    @executor.re_pair(display_name: "again")
    assert_marks_cleared @executor

    @executor.mark_connected("conn-2")
    @executor.revoke_credentials
    assert_marks_cleared @executor

    runner.mark_connected("conn-3")
    assert_equal :removed, manager.remove
    assert_equal :converged, runner.converge_human_shutdown(
      expected_human_id: manager.id,
      expected_generation: manager.managed_resource_shutdown_generation,
      expected_applied_generation: stale_applied
    )
    assert_marks_cleared runner

    @executor.mark_connected("conn-4")
    @executor.update!(last_seen_at: 1.minute.ago)
    @executor.revoke
    assert_marks_cleared @executor
    assert_not_nil @executor.last_seen_at, "the terminal revoke keeps the contact sample"
  end

  # THE DATABASE IS THE AUTHORITY for which marks are live (M4 as amended):
  # a mark is online iff the `nexus_servers` row it names is. No boot sweep —
  # a process killed without running `unsubscribed` leaves a mark that reads
  # offline once its row's heartbeat lapses, and nothing clears a sibling's.
  test "a mark under a dead server reads offline and the mark itself is untouched" do
    @executor.mark_connected("conn-dead")
    @executor.update!(last_seen_at: 2.minutes.ago)

    assert_equal "offline", Nexus::Presence.of(@executor.reload, live_server_ids: [])
    assert_equal "conn-dead", @executor.presence_connection_id
    assert_equal NexusServer.boot_id, @executor.presence_server_id
    assert_not_nil @executor.connected_at
  end

  test "a sibling's boot never clears a live process's mark" do
    NexusServer.register
    @executor.mark_connected("conn-live")
    NexusServer.create!(boot_id: SecureRandom.uuid, host: "sibling", pid: 99,
      started_at: Time.current, heartbeat_at: Time.current)

    live_ids = NexusServer.live_ids
    assert_includes live_ids, NexusServer.boot_id
    assert_equal "online", Nexus::Presence.of(@executor.reload, live_server_ids: live_ids)
    assert_equal "conn-live", @executor.presence_connection_id
  end

  test "a graceful stop turns its marks offline at once" do
    NexusServer.register
    @executor.mark_connected("conn-stop")
    @executor.update!(last_seen_at: Time.current)

    NexusServer.deregister

    assert_empty NexusServer.live_ids
    assert_equal "offline", Nexus::Presence.of(@executor.reload, live_server_ids: NexusServer.live_ids)
    assert_equal "conn-stop", @executor.presence_connection_id, "the mark row is untouched"
  end

  test "a terminal address cannot be re-paired" do
    @executor.revoke
    epoch = @executor.reload.credential_epoch

    assert_raises ArgumentError do
      @executor.re_pair(display_name: "Must not replace history")
    end

    assert_equal epoch, @executor.reload.credential_epoch
    assert_not_equal "Must not replace history", @executor.display_name
    assert_predicate @executor, :revoked?
  end

  test "eligibility requires live status and the exact epoch" do
    assert @executor.transport_authorized_at?(1)
    assert_not @executor.transport_authorized_at?(2)

    @executor.revoke
    assert_not @executor.reload.transport_authorized_at?(1)
  end

  test "Agent removal and restore preserve the address but fence its old credential epoch" do
    @agent.remove

    assert_predicate @executor.reload, :active?
    assert_not @executor.transport_authorized_at?(1)
    assert_not @executor.agent.reload.active?,
      "the Profile is inactive while its address is retained"

    users(:agent).reload.restore
    assert_predicate @executor.reload, :active?
    assert_not @executor.transport_authorized_at?(1)
  end

  test "credential readiness counts a live device credential" do
    _member, executor = create_readiness_executor
    create_bound_credential(executor: executor)

    assert_equal :ready, credential_readiness_for(executor)
  end

  test "an expired access token with a rotatable refresh family stays credential-ready" do
    member, executor = create_readiness_executor
    family = create_readiness_family(member: member, executor: executor)
    access = member.access_tokens.create!(
      refresh_token_family: family,
      credential_plane: :executor_transport,
      name: "Readiness",
      source: :oauth_device,
      lookup_id: SecureRandom.base58(24),
      secret_digest: "expired-readiness",
      expires_at: 1.hour.ago,
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation
    )
    RefreshTokens::Issue.call(refresh_token_family: family, access_token: access)

    assert_not access.reload.executor_usable?
    assert_equal :ready, credential_readiness_for(executor)
  end

  test "an epoch advance fences refresh-family credential readiness" do
    _member, executor = create_readiness_executor
    create_bound_credential(executor: executor)
    assert_equal :ready, credential_readiness_for(executor)

    advance_credential_epoch(executor)

    assert_equal :no_credential, credential_readiness_for(executor)
  end

  test "removing the Agent fences both planes while preserving its address" do
    member = create_agent_member(
      display_name: "Removal Agent",
      agent_identifier: "removal-readiness-#{SecureRandom.hex(8)}"
    )
    connection = connect_agent_session(
      steward: member.steward,
      agent_identifier: member.agent_identifier
    )
    executor = connection.executor_access_token.task_executor
    assert_equal :ready, credential_readiness_for(executor)
    assert connection.access_token.usable?
    assert connection.executor_access_token.executor_usable?

    assert_equal :removed, member.remove

    old_epoch = executor.credential_epoch
    assert_not executor.reload.transport_authorized_at?(old_epoch)
    assert_not connection.access_token.reload.usable?,
      "member/data authority must die on removal"
    assert_not connection.executor_access_token.reload.executor_usable?
    assert_equal :no_credential, credential_readiness_for(executor)
  end

  test "a user-private Runner with a live device credential is ready" do
    connection = connect_runner(
      manager: @owner,
      registration_identifier: "private-readiness",
      assignment_scope: :user_private
    )

    assert_equal :ready,
      credential_readiness_for(connection.executor_access_token.task_executor)
  end

  test "an account-wide Runner with a live device credential is ready" do
    connection = connect_runner(
      manager: @owner,
      registration_identifier: "wide-readiness",
      assignment_scope: :account_wide
    )

    assert_equal :ready,
      credential_readiness_for(connection.executor_access_token.task_executor)
  end

  test "a suspended steward does not change transport credential readiness" do
    member, executor = create_readiness_executor
    create_bound_credential(executor: executor)
    users(:member).change_role(to: :admin)
    member.account.transfer_ownership(to: users(:member).reload, by: @owner)

    assert_equal :suspended, @owner.reload.suspend

    assert_not member.reload.steward_live?, "the steward axis moved"
    assert_equal :ready, credential_readiness_for(executor),
      "and the credential axis did not"
  end

  test "an executor without a credential is not credential-ready" do
    _member, executor = create_readiness_executor

    assert_equal :no_credential, credential_readiness_for(executor)
  end

  # ── the announcement ─────────────────────────────────────────

  BASH_WRITE = {
    "kind" => "write", "destructive" => true, "effect_scope" => "open",
    "idempotency" => "none", "reconciliation" => "none",
  }.freeze

  READ_SCHEMA = { "type" => "object", "properties" => { "path" => { "type" => "string" } },
                  "required" => ["path"] }.freeze

  test "an announcement is stored canonical and read back by name" do
    outcome = @executor.announce(tools: [
      { "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
        "description" => "Read a file", "input_schema" => READ_SCHEMA, "colour" => "red" },
      { "name" => "bash", "effect_profile" => BASH_WRITE, "timeout_ms" => 30_000 },
    ])

    assert_equal :announced, outcome.outcome
    @executor.reload
    assert_equal %w[bash read_file], @executor.served_tools.map { |entry| entry["name"] },
      "ordered by name"
    assert @executor.served?("bash")
    assert_not @executor.served?("grep")
    assert_equal 30_000, @executor.serving("bash").fetch("timeout_ms")
    assert_equal({ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED,
                   "description" => "Read a file", "input_schema" => READ_SCHEMA },
      @executor.serving("read_file"), "the declaration keys are kept; unknown keys are dropped; an absent timeout is absent")
    assert_equal({ "name" => "bash", "effect_profile" => BASH_WRITE, "timeout_ms" => 30_000 },
      @executor.serving("bash"), "absent declaration keys are absent")
    assert_equal BASH_WRITE.merge("timeout_ms" => 30_000), @executor.effect_profile_for("bash")
    assert_equal Nexus::ToolRegistry::READ_ONLY_CLOSED, @executor.effect_profile_for("read_file"),
      "the frozen profile document never carries the declaration keys"
    assert_nil @executor.serving("grep")

    assert_equal :announced, @executor.announce(tools: []).outcome
    assert_equal [], @executor.reload.served_tools, "a second announcement replaces the first whole"
    assert_not @executor.served?("bash")
  end

  # The split over every kernel name in every spelling: a reserved namespace, an overridable
  # wire name.
  def kernel_names_where(&block)
    names = Nexus::ToolRegistry::LIVE.keys + Nexus::ToolRegistry::WIRE_ALIASES.keys
    names.select { |name| block.call(Nexus::ToolRegistry.resolve(name)) }
  end

  test "a kernel name under a reserved namespace is refused reserved_namespace" do
    names = kernel_names_where { |canonical| Nexus::ToolRegistry.reserved_namespace?(canonical) }
    assert_includes names, "wait"
    assert_includes names, "spawn"
    names.each do |name|
      outcome = @executor.announce(tools: [
        { "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED },
      ])
      assert_equal :reserved_namespace, outcome.outcome, name
      assert_includes outcome.detail, "reserved kernel namespace", name
    end
    assert_equal [], @executor.reload.served_tools, "a refused announcement writes nothing"
  end

  test "an overridable kernel wire name is announced and stored as announced; its dotted spelling is not" do
    wire = kernel_names_where { |canonical| Nexus::ToolRegistry.overridable?(canonical) }
    wire, dotted = wire.partition { |name| name.match?(Nexus::ToolAnnouncements::NAME_FORMAT) }
    assert_equal %w[memory_delete memory_edit memory_grep memory_ls memory_read memory_write], wire.sort
    outcome = @executor.announce(tools: wire.map { |name|
      { "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
    })
    assert_equal :announced, outcome.outcome, outcome.detail.to_s
    assert_equal wire.sort, @executor.reload.served_tools.map { |entry| entry["name"] }
    assert @executor.served?("memory_read")

    dotted.each do |name|
      outcome = @executor.announce(tools: [
        { "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED },
      ])
      assert_equal :invalid_announcement, outcome.outcome, name
      assert_includes outcome.detail, "tools[0].name must match", name
    end
    assert_equal wire.sort, @executor.reload.served_tools.map { |entry| entry["name"] },
      "a refused announcement writes nothing"
  end

  test "an entry without an effect profile, a foreign key, a value outside the vocabulary, "     "a non-positive timeout, a bad description or a bad schema is invalid_announcement" do
    profile = Nexus::ToolRegistry::READ_ONLY_CLOSED
    [
      [{ "name" => "read_file" }, "effect_profile"],
      [{ "name" => "read_file", "effect_profile" => profile.merge("extra" => 1) }, "effect_profile"],
      [{ "name" => "read_file", "effect_profile" => profile.except("effect_scope") }, "effect_profile"],
      [{ "name" => "read_file", "effect_profile" => profile.merge("kind" => "mutate") }, "effect_profile"],
      [{ "name" => "read_file", "effect_profile" => profile.merge("destructive" => "no") }, "effect_profile"],
      [{ "name" => "read_file", "effect_profile" => profile, "timeout_ms" => 0 }, "timeout_ms"],
      [{ "name" => "read_file", "effect_profile" => profile, "timeout_ms" => "30000" }, "timeout_ms"],
      [{ "name" => "read_file", "effect_profile" => profile, "description" => "" }, "description"],
      [{ "name" => "read_file", "effect_profile" => profile, "input_schema" => [] }, "input_schema"],
      [{ "name" => "read_file", "effect_profile" => profile, "input_schema" => { "type" => "string" } }, "input_schema"],
      [{ "name" => "read file", "effect_profile" => profile }, "name"],
      [{ "effect_profile" => profile }, "name"],
      ["read_file", "tools[0]"],
    ].each do |entry, field|
      outcome = @executor.announce(tools: [entry])
      assert_equal :invalid_announcement, outcome.outcome, entry.inspect
      assert_includes outcome.detail, field, entry.inspect
      assert_includes outcome.detail, "0", "the refusal names the entry index"
    end
    assert_equal :invalid_announcement, @executor.announce(tools: { "name" => "x" }).outcome,
      "an announcement is a list"
  end

  # The documents: the third list the one verb replaces whole, stored canonical by name as `{name,
  # description}` and nothing more, absent = `[]`, refused with the list (a refusal writes nothing),
  # bounded by the envelope bound.
  test "the announced documents are stored canonical and replaced whole with the list" do
    outcome = @executor.announce(tools: [], documents: [
      { "name" => "deploy-notes", "description" => "How this project is deployed.", "kind" => "skill" },
      { "name" => "commit-style", "description" => "How commits are written." },
    ])

    assert_equal :announced, outcome.outcome, outcome.detail.to_s
    assert_equal [{ "name" => "commit-style", "description" => "How commits are written." },
                  { "name" => "deploy-notes", "description" => "How this project is deployed." }],
      @executor.reload.served_documents, "ordered by name, the two keys, no kind"

    outcome = @executor.announce(tools: [], documents: [{ "name" => "PDF", "description" => "x" }])
    assert_equal :invalid_announcement, outcome.outcome
    assert_includes outcome.detail, "documents[0].name must match"
    assert_equal 2, @executor.reload.served_documents.length, "a refused announcement writes nothing"

    outcome = @executor.announce(tools: [{ "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }],
      documents: [{ "name" => "deploy-notes" }])
    assert_equal :invalid_announcement, outcome.outcome
    assert_equal "documents[0].description must be a non-empty string", outcome.detail
    assert_equal [], @executor.reload.served_tools, "the list is refused with the documents: one write shape"

    assert_equal :announced, @executor.announce(tools: []).outcome
    assert_equal [], @executor.reload.served_documents, "absent clears: whole replacement"

    entry = { "name" => "a", "description" => "d" * Nexus::Skills::DESCRIPTION_MAX_LENGTH }
    many = (1..70).map { |i| entry.merge("name" => "skill-#{i}") }
    outcome = @executor.announce(tools: [], documents: many)
    assert_equal :invalid, outcome.outcome, "seventy 1024-byte descriptions cross the envelope bound"
    assert_includes @executor.errors.full_messages.to_sentence, "Served documents"
    assert_equal [], @executor.reload.served_documents
  end

  # The environment document: opaque, whole-replaced with the list, absent = `{}`, bounded by its
  # own named bound.
  test "an environment document is stored opaque and replaced whole with the list" do
    document = { "root" => "/w", "branch" => "main", "platform" => "darwin",
                 "fragments" => [{ "extension" => "rho.coding", "text" => "Relative paths resolve against /w." }] }
    outcome = @executor.announce(tools: [], environment: document)

    assert_equal :announced, outcome.outcome
    assert_equal document, @executor.reload.environment

    assert_equal :announced, @executor.announce(tools: []).outcome
    assert_equal({}, @executor.reload.environment, "an absent environment clears it: one whole-replacement verb")
  end

  test "a non-object environment is invalid_announcement and an oversized one is invalid" do
    outcome = @executor.announce(tools: [], environment: [])
    assert_equal :invalid_announcement, outcome.outcome
    assert_equal "environment must be an object", outcome.detail
    assert_equal({}, @executor.reload.environment, "a refusal writes nothing")

    oversized = { "text" => "a" * Nexus::SizeBounds.fetch(:executor_environment_bound) }
    outcome = @executor.announce(tools: [], environment: oversized)
    assert_equal :invalid, outcome.outcome
    assert outcome.executor.errors.of_kind?(:environment, :content_too_large)
    assert_equal({}, @executor.reload.environment)
  end

  test "a duplicate name is refused" do
    outcome = @executor.announce(tools: [
      { "name" => "read_file", "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED },
      { "name" => "read_file", "effect_profile" => BASH_WRITE },
    ])

    assert_equal :invalid_announcement, outcome.outcome
    assert_includes outcome.detail, "read_file"
  end

  # ── eligibility: the first reader of assignment_scope ──

  test "an active credential-ready agent address is eligible for any principal" do
    assert_not @executor.eligible_for?(@agent), "no credential yet"
    create_bound_credential(executor: @executor)

    assert @executor.eligible_for?(@agent)
    assert @executor.eligible_for?(@owner)
    assert @executor.eligible_for?(users(:member))
  end

  test "a user_private runner serves its manager and the agents its manager stewards, no other Human" do
    runner = connect_runner(
      manager: @owner, registration_identifier: "private-eligibility", assignment_scope: :user_private
    ).executor_access_token.task_executor

    assert runner.eligible_for?(@owner), "the manager manages itself"
    assert runner.eligible_for?(@agent), "stewarded by the manager"
    assert_not runner.eligible_for?(users(:member))
    assert_not runner.eligible_for?(create_agent_member(steward: users(:member),
      agent_identifier: "foreign-steward-agent"))
  end

  test "an account_wide runner is eligible for every principal" do
    runner = connect_runner(
      manager: @owner, registration_identifier: "wide-eligibility", assignment_scope: :account_wide
    ).executor_access_token.task_executor

    assert runner.eligible_for?(@owner)
    assert runner.eligible_for?(users(:member))
    assert runner.eligible_for?(@agent)
  end

  test "a tools provider inherits the machine eligibility rule" do
    private_provider = connect_runner(
      manager: @owner, registration_identifier: "private-provider", assignment_scope: :user_private,
      executor_kind: :tool_provider
    ).executor_access_token.task_executor
    assert_predicate private_provider, :tool_provider?
    assert private_provider.eligible_for?(@owner), "the manager manages itself"
    assert private_provider.eligible_for?(@agent), "stewarded by the manager"
    assert_not private_provider.eligible_for?(users(:member)), "a user_private provider under a foreign manager"

    wide_provider = connect_runner(
      manager: @owner, registration_identifier: "wide-provider", assignment_scope: :account_wide,
      executor_kind: :tool_provider
    ).executor_access_token.task_executor
    assert wide_provider.eligible_for?(users(:member))
    assert wide_provider.eligible_for?(@agent)

    bare = @owner.account.task_executors.create!(
      executor_kind: :tool_provider, display_name: "Bare provider", registration_identifier: "bare-provider",
      manager: @owner, assignment_scope: :account_wide
    )
    assert_not bare.eligible_for?(@owner), "no credential"

    wide_provider.revoke
    assert_not wide_provider.reload.eligible_for?(@owner), "revoked"

    pending = connect_runner(
      manager: users(:member), registration_identifier: "pending-provider", assignment_scope: :user_private,
      executor_kind: :tool_provider
    ).executor_access_token.task_executor
    assert pending.eligible_for?(users(:member))
    assert_equal :removed, users(:member).remove
    assert_predicate pending.reload, :shutdown_pending?
    assert_not pending.eligible_for?(users(:member)), "the manager's shutdown generation moved"
  end

  test "a revoked, credential-less, or shutdown-pending executor is eligible for nobody" do
    bare = @owner.account.task_executors.create!(
      executor_kind: :runner, display_name: "Bare", registration_identifier: "bare",
      manager: @owner, assignment_scope: :account_wide
    )
    assert_not bare.eligible_for?(@owner), "no credential"

    revoked = connect_runner(
      manager: @owner, registration_identifier: "revoked-eligibility", assignment_scope: :account_wide
    ).executor_access_token.task_executor
    assert revoked.eligible_for?(@owner)
    revoked.revoke
    assert_not revoked.reload.eligible_for?(@owner)

    pending = connect_runner(
      manager: users(:member), registration_identifier: "pending-eligibility", assignment_scope: :user_private
    ).executor_access_token.task_executor
    assert pending.eligible_for?(users(:member))
    assert_equal :removed, users(:member).remove
    assert_not pending.reload.eligible_for?(users(:member)), "the manager's shutdown generation moved"
  end

  private

    def assert_marks_cleared(executor)
      executor.reload
      assert_nil executor.presence_connection_id
      assert_nil executor.presence_server_id
      assert_nil executor.connected_at
    end

    def credential_readiness_for(executor)
      TaskExecutor.credential_readiness_for([executor]).fetch(executor.id)
    end

    def create_readiness_executor
      member = create_agent_member(
        display_name: "Readiness Agent",
        agent_identifier: "readiness-#{SecureRandom.hex(8)}"
      )
      executor = member.task_executors.create!(
        account: member.account,
        executor_kind: :agent_application,
        display_name: "Readiness App"
      )

      [member, executor]
    end

    def create_readiness_family(member:, executor:)
      member.refresh_token_families.create!(
        account: member.account,
        access_token_name: "Readiness",
        task_executor: executor,
        credential_epoch: executor.credential_epoch,
        user_authority_generation: member.authority_generation,
        last_used_at: Time.current
      )
    end
end
