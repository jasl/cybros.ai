require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/contract_fixtures"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# The rho dedication and StoreEntry lane, one ordered scenario under the dedicated rho steward Human.
# Each fresh home supplies its own Account-unique instance identifier. Fresh device flow and daemon
# boot create exactly one dedicated private Workspace; a restart
# lists-and-adopts it without duplicating; a second Agent under the same steward proves the
# dedication fence while the Human owner stays unfenced; StoreEntry CRUD, replay, mismatch, and
# key_taken ride the same Workspace; the store's other two hosts — a conversation of that Workspace
# and the acting principal's own profile — are observed beside it; and the steward finally hands the
# row to the founding owner with the creator unchanged.
#
# SHARED PLUMBING, STATED: every test in this file drives the SAME signed-in
# steward browser (E2E::StewardSession, one per journey process); the
# daemon, its RHO_HOME and every ceremony stay per test.
class WorkspaceDedicationTest < Minitest::Test
  FENCE_AGENT_IDENTIFIER = "cybros-e2e-fence-agent".freeze

  def setup
    @base_url = E2E.base_url
    @entries_pack = E2E::ContractFixtures.store_entries
    @errors_pack = E2E::ContractFixtures.errors
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-workspace-e2e")
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(File.join(@home, "log", "rho.log"), "rho structured log") if @home
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/workspace_dedication-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho workspace E2E capture: #{error.class}: #{error.message}"
  ensure
    [@daemon, @second].compact.each do |daemon|
      if (result = daemon.dispose_connection)
        output, status = result
        assert_predicate status, :success?, output
      end
    end
    [@home, @second&.home].compact.each { |home| FileUtils.remove_entry(home) if File.directory?(home) }
  end

  def test_rho_dedicates_one_workspace_fences_other_agents_and_hands_it_to_the_founding_owner
    steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)

    # Fresh Agent device flow plus daemon boot: the daemon discovers no
    # dedicated Workspace and creates exactly one, private, without waiting
    # for a renewal interval.
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    adopted = await_workspace_state("adopted")
    workspace_public_id = adopted.dig("workspace", "public_id")
    rho_profile_public_id = adopted.dig("identity", "user_public_id")
    refute_nil workspace_public_id
    refute_nil rho_profile_public_id

    rows = dedicated_rows(steward_client, creator: rho_profile_public_id)
    assert_equal [workspace_public_id], rows.map(&:public_id), "exactly one dedicated Workspace exists for this rho"
    summary = rows.first
    assert summary.dedicated, "the only public dedication marker is the boolean"
    assert_equal "private", summary.access_mode, "an Agent create always forces private"
    assert_equal "active", summary.state

    # The Full projection proves the ownership triangle: the steward Human
    # owns, the rho Agent created, and the daemon's announced name
    # is the row's name.
    full = steward_client.workspaces.fetch(workspace_public_id)
    assert_equal @steward.public_id, full.owner.public_id
    assert_equal rho_profile_public_id, full.creator.public_id
    assert_equal "agent", full.creator.kind
    assert_equal adopted.dig("workspace", "name"), full.name

    # TWO HOMES UNDER ONE STEWARD: a second install of the SAME program on a second RHO_HOME
    # presents `rho.<its own instance>` — the id derived at its first boot, never typed — and pairs
    # as a SEPARATE Profile with its own dedicated Workspace. The kernel publishes no identifier
    # (the product-code tag reaches no public surface), so the two rows are read as two creators and
    # the two ids from each home's `instance.json` and its `rho status`.
    second_home, second_profile_public_id, second_workspace_public_id = pair_a_second_home(steward_client)
    refute_equal rho_profile_public_id, second_profile_public_id, "a second home is a second Profile, not a re-pair"
    refute_equal workspace_public_id, second_workspace_public_id
    assert_equal [second_workspace_public_id], dedicated_rows(steward_client, creator: second_profile_public_id).map(&:public_id)
    assert_equal [workspace_public_id], dedicated_rows(steward_client, creator: rho_profile_public_id).map(&:public_id),
      "the first install's dedication is untouched by the second"

    # A restart lists before it ever creates: the same Workspace is adopted
    # and no sibling appears — and, after the second install paired, the
    # restart is the kernel-proven fact that it FENCED NOTHING: a fenced
    # device could not adopt (its grant would be revoked by the re-pair).
    @daemon.stop
    @daemon.start
    readopted = await_workspace_state("adopted")
    assert_equal workspace_public_id, readopted.dig("workspace", "public_id"),
      "a restart adopts the same dedicated Workspace"
    assert_equal rho_profile_public_id, readopted.dig("identity", "user_public_id"), "the same Profile: the same home"
    assert_equal [workspace_public_id], dedicated_rows(steward_client, creator: rho_profile_public_id).map(&:public_id),
      "a restart never duplicates the dedicated Workspace"
    first_status, = @daemon.cli("status")
    assert_match(/^instance:  #{instance_id(@home)}$/, first_status, first_status)
    refute_match(/^state:     (not connected|credentials expired)/, first_status, "the first install is still connected:\n#{first_status}")
    output, status = @second.dispose_connection
    assert_predicate status, :success?, output
    FileUtils.remove_entry(second_home) if File.directory?(second_home)

    # All daemon assertions are done; stop it so a later maintenance cycle
    # cannot race the transfer at the end of the lane.
    @daemon.stop

    # The steward Human is never fenced: full StoreEntry CRUD rides this
    # Workspace, including replay, mismatch, and key_taken.
    entries = steward_client.workspace(workspace_public_id).store_entries
    entry = verify_store_entry_crud_prelude(entries)

    # A second Agent under the same steward with a different identifier:
    # reads pass, every write is fenced with the dedication mismatch, and
    # owner management stays server-side.
    fence_client = verify_dedication_fence(workspace_public_id, entry)

    # The store's other two hosts on the same Workspace: a conversation's
    # (fenced through its workspace) and each principal's own profile
    # (never fenced, per principal, no receipt).
    verify_store_hosts(steward_client, workspace_public_id, fence_client)

    # The steward completes the CRUD: update to a stored JSON null, then
    # delete to the family's one empty answer.
    verify_store_entry_crud_epilogue(entries, entry)

    # Finally the steward hands the Workspace to the founding owner; the
    # creator remains the rho Agent.
    current = steward_client.workspaces.fetch(workspace_public_id)
    handed = steward_client.workspace(workspace_public_id).transfer_ownership(
      target_user_public_id: @world.owner_public_id, lock_version: current.lock_version
    )
    assert_equal @world.owner_public_id, handed.owner.public_id
    assert_equal rho_profile_public_id, handed.creator.public_id, "transfer never rewrites the creator"
    assert_equal "agent", handed.creator.kind
  end

  # One model step declaring the kernel memory tools, scripted to call
  # them in sequence.
  #
  # THE DECLARATIONS COME FROM THE CATALOG, not from this file, and that
  # is not tidiness: a task declaring a kernel tool must send
  # BYTE-IDENTICAL bytes or the compile door refuses
  # `kernel_tool_redefined`, because the tools block is the front of every
  # cached prefix. Transcribing them here is exactly the thing no client
  # can get right, which is why the catalog route exists.
  def memory_round(script)
    { model: {
      key: "m1", model: { model: "dev/mock-text" },
      tools: kernel_memory_tools,
      prompt: "!mock tool_call=#{script} -- remember it",
    } }
  end

  def kernel_memory_tools
    @kernel_memory_tools ||= agent_api(:get, "/agent_api/v1/tools")
      .fetch("tools")
      .select { |tool| tool.fetch("canonical_name").start_with?("nexus.memory.") }
      .map { |tool| tool.fetch("definition") }
  end

  def task_output(workspace_public_id, run_public_id, key)
    agent_api(:get, "/agent_api/v1/workspaces/#{workspace_public_id}" \
      "/runs/#{run_public_id}/tasks/#{key}").dig("task", "output").to_s
  end

  # The failure has to say what the loop was actually doing, or a stall is
  # indistinguishable from a runner that never woke.
  def await_loop_completion(&probe) = await_run_status("completed", &probe)

  # THE MEMBER PLANE IS RATE-LIMITED PER CALLER (120 a minute on the loop
  # routes) and every case here reads as the same steward, so a loop poll
  # is paced, never at the daemon's readiness cadence: five reads a second
  # spent the budget in 24 s of a loaded paired round, and every read after
  # answered `rate_limited` — which this helper reported as "last seen nil".
  LOOP_POLL = 1

  def await_run_status(status, &probe)
    latest = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + E2E::RhoDaemon::READY_TIMEOUT
    loop do
      latest = probe.call
      return latest if latest && latest["status"] == status
      flunk "the loop never reached #{status}; last seen #{latest.inspect}" if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep LOOP_POLL
    end
  end

  require_relative "workspace_dedication/protocol_and_store"
  include ProtocolAndStore
end
