require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "create_with_owner founds account, system user, and owner together" do
    Account.destroy_all

    account = Account.create_with_owner(
      account: { name: "Example" },
      owner: { email: " Owner@Example.COM ", display_name: "Owner", password: "correct horse battery", password_confirmation: "correct horse battery" }
    )

    assert_equal "Example", account.name
    assert account.public_id.present?

    system_user = account.users.find_by!(role: :system)
    assert system_user.agent?
    assert_equal User::SYSTEM_DISPLAY_NAME, system_user.display_name
    assert_nil system_user.identity

    owner = account.owner
    assert owner.human?
    assert owner.active?
    assert_equal "owner@example.com", owner.identity.email
    assert owner.identity.authenticate("correct horse battery")

    # Founding seeds principals only. There is no default Workspace: a Human creates their first
    # container explicitly and an Agent finds-or-creates its own at runtime.
    assert account.workspaces.none?
  end

  test "create_with_owner hashes the owner credential before opening its transaction" do
    Account.destroy_all
    connection = ActiveRecord::Base.lease_connection
    baseline_transactions = connection.open_transactions
    hashing_transactions = []
    bcrypt_create = BCrypt::Password.method(:create)

    BCrypt::Password.stub(:create, ->(*args, **kwargs) {
      hashing_transactions << connection.open_transactions
      bcrypt_create.call(*args, **kwargs)
    }) do
      Account.create_with_owner(
        account: { name: "Example" },
        owner: { email: "owner@example.com", display_name: "Owner", password: "correct horse battery", password_confirmation: "correct horse battery" }
      )
    end

    # Fixture isolation already owns the baseline transaction. Founding must
    # not add another one until after BCrypt has finished.
    assert_equal [baseline_transactions], hashing_transactions
  end

  test "a second founding loses on the singleton guard and creates nothing" do
    assert_no_difference [-> { Account.count }, -> { User.count }, -> { Identity.count }, -> { Workspace.count }] do
      assert_raises ActiveRecord::RecordNotUnique do
        Account.create_with_owner(
          account: { name: "Second" },
          owner: { email: "second@example.com", display_name: "Second", password: "correct horse battery", password_confirmation: "correct horse battery" }
        )
      end
    end
  end

  test "an invalid owner leaves no partial founding world" do
    Account.destroy_all

    assert_no_difference [-> { Account.count }, -> { User.count }, -> { Identity.count }] do
      assert_raises ActiveRecord::RecordInvalid do
        Account.create_with_owner(
          account: { name: "Example" },
          owner: { email: "not-an-email", display_name: "Owner", password: "correct horse battery", password_confirmation: "correct horse battery" }
        )
      end
    end
  end

  test "a null-byte owner password leaves no partial founding world" do
    Account.destroy_all
    error = nil

    assert_no_difference [-> { Account.count }, -> { User.count }, -> { Identity.count }, -> { Workspace.count }] do
      error = assert_raises ActiveRecord::RecordInvalid do
        Account.create_with_owner(
          account: { name: "Example" },
          owner: {
            email: "owner@example.com",
            display_name: "Owner",
            password: "correct\0horse battery",
            password_confirmation: "correct\0horse battery",
          }
        )
      end
    end

    assert error.record.errors.of_kind?(:password, :invalid)
  end

  test "name is required and bounded" do
    account = accounts(:cybros)

    assert_not account.update(name: "")
    assert_not account.update(name: "a" * (Account::NAME_MAX_LENGTH + 1))
    assert account.update(name: "Renamed")
  end

  test "destroy removes credential and device leaves before their authority owners" do
    account = accounts(:cybros)
    member = users(:agent)
    executor = task_executors(:address)
    family = member.refresh_token_families.create!(
      account: account,
      access_token_name: "Device pairing",
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation,
      last_used_at: Time.current
    )
    access = member.access_tokens.create!(
      account: account,
      refresh_token_family: family,
      credential_plane: :executor_transport,
      name: family.access_token_name,
      source: :oauth_device,
      lookup_id: SecureRandom.base58(24),
      secret_digest: "seed",
      expires_at: AccessToken::OAUTH_TTL.from_now,
      task_executor: executor,
      credential_epoch: executor.credential_epoch,
      user_authority_generation: member.authority_generation
    )
    refresh = RefreshTokens::Issue.call(
      refresh_token_family: family,
      access_token: access
    ).token
    authorization = DeviceAuthorizations::Issue.call(
      account: account,
      agent_identifier: member.agent_identifier,
      agent_display_name: member.display_name,
      requested_executor_display_name: executor.display_name,
    ).authorization
    authorization.update!(
      status: :consumed,
      user: member,
      connected_by: users(:owner),
      connected_by_authority_generation: users(:owner).authority_generation,
      task_executor: executor,
      access_token: access,
      refresh_token: refresh
    )
    # The leaf the cascade once forgot: three NOT NULL FKs (account, identity,
    # user), so a single minted recovery used to fail the whole destroy with a
    # ForeignKeyViolation at the users DELETE.
    recovery = MemberRecoveryAuthorizations::Issue.call(user: users(:owner))
    assert_equal :issued, recovery.outcome

    assert_difference -> { Account.count }, -1 do
      account.destroy!
    end

    assert_not DeviceAuthorization.exists?(authorization.id)
    assert_not RefreshToken.exists?(refresh.id)
    assert_not AccessToken.exists?(access.id)
    assert_not RefreshTokenFamily.exists?(family.id)
    assert_not TaskExecutor.exists?(executor.id)
    assert_not User.exists?(member.id)
  end

  test "destroy removes model-work leaves before their shared owners" do
    account = accounts(:cybros)
    creator = users(:member)
    workspace = workspaces(:shared)
    bytes = "complete-upload"
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes), filename: "input.bin", content_type: "application/octet-stream"
    )
    upload = account.content_uploads.create!(
      creating_user: creator,
      file: blob
    )
    payload = { "text" => "input" }
    address = Nexus::ContentAddress.for(account_id: account.id, payload: payload)
    fragment = account.content_fragments.create!(
      payload: payload, digest: address.digest
    )
    selection = DevModelLane.selection(workload: "text_generation")
    one_shot = OneShot.create!(
      workspace: workspace,
      creating_user: creator,
      workload: selection.workload
    )
    body = one_shot.content_bodies.create!(role: "input")
    entry = body.content_body_entries.create!(
      account: account, content_fragment: fragment, position: 0
    )
    body.content_body_uploads.create!(content_upload: upload)
    invocation = DevModelLane.create_invocation!(
      one_shot: one_shot, selection: selection,
      internal_creation_key: SecureRandom.uuid
    )
    receipt = OneShotCreateReceipt.create!(
      one_shot: one_shot,
      idempotency_key: "account-teardown",
      request_digest: OneShotCreateReceipt.digest_for(
        workload: one_shot.workload, envelope: { "input" => "hello" }
      ),
      result: { "one_shot_public_id" => one_shot.public_id }
    )
    storage_attachment_id = upload.file.attachment.id
    # Provider-lane leaves: each holds a bare accounts FK, so either one left
    # out of the cascade fails the whole destroy.
    policy = account.model_provider_policies.create!(
      provider_id: "codex_subscription", enabled: true,
      model_overrides: ModelProviderPolicy.empty_overrides
    )
    credential = account.model_provider_credentials.create!(
      provider_id: "openai_api", material_kind: "api_key", secret: "sk-teardown"
    )
    # The OAuth authorization vertical, which was the one account-scoped pair
    # this test never built — and so the one pair the cascade never named. A
    # session holds an `issuing_user_id` FK, so its absence aborted the whole
    # destroy on `users` for any installation that had ever started a Codex
    # device authorization. It is driven through the real acceptance command
    # rather than hand-built, because a hand-built row is what the previous
    # coverage gaps had in common.
    oauth_session = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: account, issuing_user: creator, kind: "device_start"
    ).session
    oauth_task = oauth_session.oauth_tasks.create!(
      account: account, exchange_kind: "user_code_request",
      claimed_at: Time.current, deadline_at: 5.minutes.from_now
    )
    # Usage/billing leaves (C2-3): budgets and grouping identities hold a
    # USER FK, the receipt family holds a bare accounts FK, and an Attempt
    # holds its Invocation under RESTRICT — any one of them left out of the
    # cascade fails the whole destroy (audit 2026-08-15).
    Accounts::ConfigureCostUnit.call(account: account, cost_unit: "USD")
    budget = UsageBudget.create!(
      account: account, user: creator, user_public_id: creator.public_id,
      user_kind: creator.kind, starts_at: Time.current, credited_amount: BigDecimal("10"),
      last_entry_sequence: 1
    )
    budget.entries.create!(
      account_public_id: account.public_id, user_public_id: creator.public_id,
      entry_sequence: 1, kind: "initial_grant", amount: BigDecimal("10"),
      cost_unit: "USD", actor_public_id: creator.public_id, operation_key: "account-teardown"
    )
    subject = BillingSubject.create!(account: account, owning_user: creator, key: "teardown")
    attempt = ModelInvocationAttempt.create!(
      account: account, model_invocation: invocation, ordinal: 1, admission_shape: "priced",
      deadline_at: 10.minutes.from_now
    )
    usage_record = UsageRecord.create!(
      account: account, idempotency_key: "account-teardown",
      model_invocation_public_id: invocation.public_id, attempt_ordinal: 1,
      consumer_user_public_id: creator.public_id, provider_id: "dev",
      catalog_model_ref: "dev/mock-text", wire_model_id: "mock-text",
      workload: "text_generation", purpose: "one_shot_attempt",
      service_class: "interactive", admission_shape: "priced",
      status: "succeeded", recorded_at: Time.current,
      cost_unit: "USD", cost_amount: BigDecimal("0.001")
    )
    grant_entry = budget.entries.sole

    # The rollup planes (item 7): any account that ever recorded a receipt
    # holds a summary row, and buckets accrue with the drain — both must
    # ride the cascade or the final accounts DELETE raises (re-audit).
    summary = ModelUsageSummary.create!(
      account: account, subject_kind: "one_shot", subject_id: one_shot.id
    )
    ModelUsageTimeBucket.increment_for_usage_records(
      [usage_record], bucket_kind: "hour", rolled_up_at: Time.current
    )
    bucket = ModelUsageTimeBucket.where(account: account).sole
    # Memory: a `user/` row holds a users FK and a `workspace/` row a workspaces FK, both under the
    # RESTRICT of their version — an account that had ever written a note failed at the accounts
    # DELETE before the cascade named them, because this test wrote none.
    user_note = memory_write!(Scopes::Anchor.call(path: "user/notes.md", user: creator))
    workspace_note = memory_write!(
      Scopes::Anchor.call(path: "workspace/notes.md", workspace: workspace)
    )
    # The store over three hosts: the user-anchored row is the one only the account's own line
    # reaches — the workspace and conversation hosts take theirs through their own cascades.
    conversation = Conversation.create!(workspace: workspace, creating_user: creator)
    store_rows = [workspace, conversation, creator].map do |host|
      StoreEntries::Create.call(host: host, by: creator, namespace: "n", key: "k").tap do |result|
        assert_equal :created, result.outcome, host.class.name
      end.entry
    end

    assert_difference -> { Account.count }, -1 do
      account.destroy!
    end

    assert_not MemoryDocument.exists?(user_note.id)
    assert_not MemoryDocument.exists?(workspace_note.id)
    store_rows.each { |row| assert_not StoreEntry.exists?(row.id), row.host.class.name }
    assert_not MemoryDocumentVersion.exists?(user_note.memory_document_version_id)
    assert_not MemoryDocumentVersion.exists?(workspace_note.memory_document_version_id)

    assert_not UsageBudgetEntry.exists?(grant_entry.id)
    assert_not UsageBudget.exists?(budget.id)
    assert_not BillingSubject.exists?(subject.id)
    assert_not UsageRecord.exists?(usage_record.id)
    assert_not ModelUsageSummary.exists?(summary.id)
    assert_not ModelUsageTimeBucket.exists?(bucket.id)
    assert_not ModelInvocationAttempt.exists?(attempt.id)
    assert_not ModelProviderPolicy.exists?(policy.id)
    assert_not ModelProviderCredential.exists?(credential.id)
    assert_not ModelProviderOAuthTask.exists?(oauth_task.id)
    assert_not ModelProviderOAuthSession.exists?(oauth_session.id)
    assert_not OneShotCreateReceipt.exists?(receipt.id)
    assert_not ModelInvocation.exists?(invocation.id)
    assert_not ContentBodyEntry.exists?(entry.id)
    assert_not ContentBodyUpload.exists?(content_body: body, content_upload: upload)
    assert_not ContentBody.exists?(body.id)
    assert_not OneShot.exists?(one_shot.id)
    assert_not ContentFragment.exists?(fragment.id)
    assert_not ContentUpload.exists?(upload.id)
    assert_not Workspace.exists?(workspace.id)
    assert_not User.exists?(creator.id)
    assert_not ActiveStorage::Attachment.exists?(storage_attachment_id)
    assert ActiveStorage::Blob.exists?(blob.id),
      "Account teardown leaves storage cleanup to asynchronous blob purge"
  end

  private

    def memory_write!(anchor)
      MemoryDocument.transaction do
        anchor.lockable.lock!
        MemoryDocuments::Write.call(anchor: anchor, expected: memory_expectation_at(anchor), content: "x").document
      end
    end
end
