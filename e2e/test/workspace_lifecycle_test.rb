require "test_helper"
require "securerandom"
require "support/actor_provisioning"
require "support/contract_fixtures"

# The Workspace lifecycle lane, SDK-driven under the lifecycle source and transfer recipient member
# credentials: no default Workspace, receipt-idempotent creation, owner management while the source
# owns the row, transfer with a stable creator, archive/restore/delete acceptances observed through
# reads and writes, stale-CAS recovery that cannot reverse newer state, recycle-bin visibility, and
# tombstone concealment. Every observed state and error code must be a member of the checked-in
# contract fixture pack's closed lists.
class WorkspaceLifecycleTest < Minitest::Test
  class DropSuccessfulCreateResponseTransport
    attr_reader :dropped_status

    def initialize(delegate:)
      @delegate = delegate
      @dropped_status = nil
    end

    def call(path, method: :get, credential: nil, body: nil, params: nil, headers: {}, timeout:)
      response = @delegate.call(
        path,
        method: method,
        credential: credential,
        body: body,
        params: params,
        headers: headers,
        timeout: timeout
      )
      if @dropped_status.nil? &&
          path == CybrosAgent::Api::Workspaces::PATH &&
          method == :post &&
          response.status == 201
        @dropped_status = response.status
        raise CybrosAgent::TransportError, "simulated response loss after Workspace creation"
      end

      response
    end
  end

  STATE_TIMEOUT = 30
  POLL = 0.2

  def setup
    @base_url = E2E.base_url
    @workspace_pack = E2E::ContractFixtures.workspaces
    @entries_pack = E2E::ContractFixtures.store_entries
    @errors_pack = E2E::ContractFixtures.errors
    @source, @recipient = E2E::ActorProvisioning.world(@base_url).lifecycle_pair
    @source_client = CybrosAgent::Client.new(base_url: @base_url, credential: @source.member_token)
    @recipient_client = CybrosAgent::Client.new(base_url: @base_url, credential: @recipient.member_token)
  end

  def test_the_strict_serial_lifecycle_through_its_observable_acceptances
    # No default Workspace exists anywhere: the freshly provisioned source
    # Human has created nothing on either scope. Read off the rows this
    # Human CREATED (`own_rows`), never off the bare listing: the world is
    # shared with other files, and an `account_wide` room another lane
    # opened is listed for every member of the account, this one included.
    initial = @source_client.workspaces.list
    assert_empty own_rows(@source_client, creator: @source.public_id),
      "a fresh Human owns nothing, yet its listing carries: #{initial.items.inspect}"
    assert_nil initial.next_after
    assert_empty own_rows(@source_client, creator: @source.public_id, state: "archived")

    # The first create reaches Nexus and commits, but its successful response
    # is deliberately dropped after the transport receives it. The caller
    # therefore has an unknown outcome and must recover through an exact
    # same-key replay rather than using any facts from the first response.
    name = "Lifecycle row #{SecureRandom.hex(4)}"
    create_key = SecureRandom.uuid
    metadata = { "purpose" => "lifecycle", "round" => "2026-07-30" }
    dropped_transport = DropSuccessfulCreateResponseTransport.new(
      delegate: CybrosAgent::HttpTransport.new(base_url: @base_url)
    )
    uncertain_client = CybrosAgent::Client.new(
      base_url: @base_url, credential: @source.member_token, transport: dropped_transport
    )
    assert_raises(CybrosAgent::TransportError) do
      uncertain_client.workspaces.create(name: name, metadata: metadata, idempotency_key: create_key)
    end
    assert_equal 201, dropped_transport.dropped_status,
      "the simulated loss happens only after Nexus answers the committed create"

    # Exact replay is the first response the caller can observe. It proves
    # the required Human owner and immutable creator.
    replayed = @source_client.workspaces.create(name: name, metadata: metadata, idempotency_key: create_key)
    assert replayed.replayed?
    created = replayed.workspace
    assert_contract_state(created.state)
    assert_equal "active", created.state
    assert_contract_access_mode(created.access_mode)
    assert_equal "private", created.access_mode, "a Human create without a mode lands private"
    refute created.dedicated, "a Human can never create a dedicated workspace"
    assert_equal @source.public_id, created.owner.public_id
    assert_equal @source.public_id, created.creator.public_id
    assert_equal @workspace_pack.dig("valid_full_fixture", "workspace", "creator", "kind"),
      created.creator.kind
    assert_equal metadata, created.metadata

    # Public refetch observes the replayed row, while a different digest
    # under the same key is refused.
    refetched = @source_client.workspaces.fetch(created.public_id)
    assert_equal created.public_id, refetched.public_id
    assert_equal created.created_at, refetched.created_at
    mismatch = assert_raises(CybrosAgent::Api::Conflict) do
      @source_client.workspaces.create(name: "#{name} differently", metadata: metadata, idempotency_key: create_key)
    end
    assert_equal "idempotency_envelope_mismatch", assert_contract_error(mismatch.code)
    assert_equal [created.public_id], own_rows(@source_client, creator: @source.public_id),
      "replay and mismatch left exactly one row"

    # While the source still owns the row: rename, whole-metadata
    # replacement, and the access-mode change.
    source_context = @source_client.workspace(created.public_id)
    renamed = source_context.update(name: "#{name} renamed", lock_version: created.lock_version)
    assert_equal "#{name} renamed", renamed.name
    replaced = source_context.update(metadata: { "phase" => "two" }, lock_version: renamed.lock_version)
    assert_equal({ "phase" => "two" }, replaced.metadata, "metadata is replaced whole, never merged")
    assert_equal "#{name} renamed", replaced.name
    opened = source_context.update_access_mode(access_mode: "account_wide", lock_version: replaced.lock_version)
    assert_equal "account_wide", assert_contract_access_mode(opened.access_mode)

    # Transfer to the recipient: the owner moves, the creator does not, and
    # the ex-owner's next management command earns the honest refusal.
    transferred = source_context.transfer_ownership(
      target_user_public_id: @recipient.public_id, lock_version: opened.lock_version
    )
    assert_equal @recipient.public_id, transferred.owner.public_id
    assert_equal @source.public_id, transferred.creator.public_id, "transfer never rewrites the creator"
    refused = assert_raises(CybrosAgent::Api::Forbidden) do
      source_context.update(name: "#{name} reclaimed", lock_version: transferred.lock_version)
    end
    assert_equal "not_workspace_owner", assert_contract_error(refused.code)

    # Archive acceptance: reads stay open on the browsable row for both
    # Humans while StoreEntry writes are refused on the non-active state.
    recipient_context = @recipient_client.workspace(created.public_id)
    accepted = recipient_context.archive(lock_version: transferred.lock_version)
    assert_contract_state(accepted.state)
    archived = await_state("archived", client: @recipient_client, public_id: created.public_id)
    pre_restore_lock = archived.lock_version
    assert_equal created.public_id, @recipient_client.workspaces.fetch(created.public_id).public_id
    assert_equal created.public_id, @source_client.workspaces.fetch(created.public_id).public_id,
      "an account-wide row stays readable to the ex-owner while archived"
    assert_empty recipient_context.store_entries.list.items, "StoreEntry reads stay open while archived"
    blocked = assert_raises(CybrosAgent::Api::Conflict) do
      recipient_context.store_entries.create(
        namespace: "e2e", key: "blocked-while-archived", value: { "kept" => false },
        idempotency_key: SecureRandom.uuid
      )
    end
    assert_equal "workspace_not_active", assert_contract_error(blocked.code)

    # The recycle bin lists the archived row; the default live scope does not.
    refute_includes @recipient_client.workspaces.list.items.map(&:public_id), created.public_id
    assert_includes @recipient_client.workspaces.list(state: "archived").items.map(&:public_id), created.public_id

    # Restore acceptance returns live access and writes.
    restored = recipient_context.restore(lock_version: pre_restore_lock)
    assert_contract_state(restored.state)
    await_state("active", client: @recipient_client, public_id: created.public_id)
    entry = recipient_context.store_entries.create(
      namespace: "e2e", key: "after-restore", value: { "kept" => true },
      idempotency_key: SecureRandom.uuid
    ).store_entry
    assert_equal({ "kept" => true }, entry.value)

    # The store's other two hosts ride the restored Workspace: a conversation's entries are the
    # conversation's — absent from the Workspace's list, one (namespace, key) per host — and a
    # person's profile store is that person's alone, kept without a receipt, so the SAME key retried
    # is key_taken rather than a replay.
    chat = recipient_context.conversations.create(
      title: "Lifecycle store host", idempotency_key: SecureRandom.uuid
    )
    conversation_entries = recipient_context.conversation(chat.public_id).store_entries
    conversation_entry = conversation_entries.create(
      namespace: "e2e", key: "in-conversation", value: { "host" => "conversation" },
      idempotency_key: SecureRandom.uuid
    ).store_entry
    assert_equal({ "host" => "conversation" }, conversation_entry.value)
    taken = assert_raises(CybrosAgent::Api::Conflict) do
      conversation_entries.create(
        namespace: "e2e", key: "in-conversation", value: { "host" => "again" },
        idempotency_key: SecureRandom.uuid
      )
    end
    assert_equal "key_taken", assert_contract_error(taken.code)
    refute_includes recipient_context.store_entries.list.items.map(&:public_id), conversation_entry.public_id,
      "a conversation's entry is not the Workspace's"
    assert_includes conversation_entries.list.items.map(&:public_id), conversation_entry.public_id
    mine_key = SecureRandom.uuid
    mine = @recipient_client.profile.store_entries.create(
      namespace: "e2e", key: "mine", value: { "whose" => "recipient" }, idempotency_key: mine_key
    ).store_entry
    assert_equal({ "whose" => "recipient" }, mine.value)
    retried = assert_raises(CybrosAgent::Api::Conflict) do
      @recipient_client.profile.store_entries.create(
        namespace: "e2e", key: "mine", value: { "whose" => "recipient" }, idempotency_key: mine_key
      )
    end
    assert_equal "key_taken", assert_contract_error(retried.code)
    refute_includes @source_client.profile.store_entries.list.items.map(&:key), "mine",
      "a profile store is per principal"

    # Stale-CAS recovery: replaying archive with the pre-restore version
    # cannot reverse the newer restored state; the recovery is refetching
    # the current row and deciding again with its lock_version.
    stale = assert_raises(CybrosAgent::Api::Conflict) do
      recipient_context.archive(lock_version: pre_restore_lock)
    end
    assert_equal "stale_object", assert_contract_error(stale.code)
    recovered = @recipient_client.workspaces.fetch(created.public_id)
    assert_equal "active", recovered.state, "the stale replay reversed nothing"

    # Delete from active, then the tombstone conceals every surface.
    deleted = recipient_context.delete(lock_version: recovered.lock_version)
    assert_includes @workspace_pack.fetch("visibility").fetch("tombstoned"), assert_contract_state(deleted.state)
    assert_raises(CybrosAgent::Api::NotFound) { @recipient_client.workspaces.fetch(created.public_id) }
    assert_raises(CybrosAgent::Api::NotFound) { @source_client.workspaces.fetch(created.public_id) }
    refute_includes @recipient_client.workspaces.list.items.map(&:public_id), created.public_id
    refute_includes @recipient_client.workspaces.list(state: "archived").items.map(&:public_id), created.public_id

    # The tombstone takes the conversation's store with the conversation's
    # route, while the person's profile store outlives the Workspace: the
    # observable form of "user-anchored entries never gate the collect".
    assert_raises(CybrosAgent::Api::NotFound) { conversation_entries.list }
    assert_includes @recipient_client.profile.store_entries.list.items.map(&:key), "mine",
      "a person's store outlives every workspace they used"

    # A second row proves delete acceptance from archived as well.
    second = @recipient_client.workspaces.create(
      name: "Lifecycle second row #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    ).workspace
    second_context = @recipient_client.workspace(second.public_id)
    second_context.archive(lock_version: second.lock_version)
    second_archived = await_state("archived", client: @recipient_client, public_id: second.public_id)
    assert_includes @recipient_client.workspaces.list(state: "archived").items.map(&:public_id), second.public_id
    second_deleted = second_context.delete(lock_version: second_archived.lock_version)
    assert_includes @workspace_pack.fetch("visibility").fetch("tombstoned"), assert_contract_state(second_deleted.state)
    assert_raises(CybrosAgent::Api::NotFound) { @recipient_client.workspaces.fetch(second.public_id) }
    refute_includes @recipient_client.workspaces.list(state: "archived").items.map(&:public_id), second.public_id
  end

  private

  # THE ROWS A HUMAN CREATED, on one listing scope: two files share one
  # world (journey_groups: the private pairs are free fillers), and an
  # `account_wide` room another lane opened — the group chat's — is listed
  # for every member of the account, so a statement about "everything this
  # Human owns" is read by the creator the fetch carries, the same id the creator
  # assertion pins; never by archiving another lane's room out of the listing.
  def own_rows(client, creator:, state: nil)
    listing = state ? client.workspaces.list(state: state) : client.workspaces.list
    listing.items.map(&:public_id).select do |public_id|
      client.workspaces.fetch(public_id).creator.public_id == creator
    end
  end

  # Acceptance commits the transition state; completion is inline
  # best-effort with the recurring sweep as the correctness owner, so the
  # lane waits on the public read rather than assuming the optimization.
  def await_state(state, client:, public_id:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STATE_TIMEOUT
    loop do
      row = client.workspaces.fetch(public_id)
      assert_contract_state(row.state)
      return row if row.state == state

      flunk "the workspace never completed to #{state} (last: #{row.state})" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep POLL
    end
  end

  def assert_contract_state(state)
    assert_includes @workspace_pack.fetch("states"), state,
      "observed state outside the contract pack's closed list"
    state
  end

  def assert_contract_access_mode(access_mode)
    assert_includes @workspace_pack.fetch("access_modes"), access_mode,
      "observed access mode outside the contract pack's closed list"
    access_mode
  end

  def assert_contract_error(code)
    known = @workspace_pack.fetch("error_codes") + @entries_pack.fetch("error_codes") +
      @errors_pack.fetch("family_codes")
    assert_includes known, code, "observed error code outside the contract pack's closed lists"
    code
  end
end
