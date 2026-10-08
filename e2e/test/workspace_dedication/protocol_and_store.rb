class WorkspaceDedicationTest
  module ProtocolAndStore
    private

      # The MEMBER plane, as the person who owns the work.
      def agent_api(verb, path, body: nil)
        uri = URI.join(@base_url, path)
        request = verb == :get ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@steward.member_token}"
        request["Content-Type"] = "application/json"
        request["Idempotency-Key"] = SecureRandom.uuid if verb == :post
        request.body = JSON.generate(body) if body
        response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
        JSON.parse(response.body)
      end

      # ---- the steward's StoreEntry surface ----

      def verify_store_entry_crud_prelude(entries)
        value = { "pinned" => { "answer" => 42 } }
        create_key = SecureRandom.uuid
        receipt = entries.create(namespace: "e2e", key: "pinned", value: value, idempotency_key: create_key)
        refute receipt.replayed?
        created = receipt.store_entry
        assert_equal value, created.value

        # Same key, exact envelope: the stored creation replays instead of a
        # second row. A different digest under the same key is refused, and a
        # fresh key against the same (namespace, key) loses to key_taken.
        replayed = entries.create(namespace: "e2e", key: "pinned", value: value, idempotency_key: create_key)
        assert replayed.replayed?
        assert_equal created.public_id, replayed.store_entry.public_id
        mismatch = assert_raises(CybrosAgent::Api::Conflict) do
          entries.create(namespace: "e2e", key: "pinned", value: { "pinned" => false }, idempotency_key: create_key)
        end
        assert_equal "idempotency_envelope_mismatch", assert_contract_error(mismatch.code)
        taken = assert_raises(CybrosAgent::Api::Conflict) do
          entries.create(namespace: "e2e", key: "pinned", value: value, idempotency_key: SecureRandom.uuid)
        end
        assert_equal "key_taken", assert_contract_error(taken.code)

        # Basic versus Full: the list summary carries no value member at all,
        # while the Full projection always does.
        summary = entries.list.items.find { |item| item.public_id == created.public_id }
        refute_nil summary
        refute_respond_to summary, :value, "Basic must not carry a value that could shadow a stored null"
        fetched = entries.fetch(created.public_id)
        assert_equal value, fetched.value
        fetched
      end

      def verify_store_entry_crud_epilogue(entries, entry)
        updated = entries.update(entry.public_id, value: nil, lock_version: entry.lock_version)
        assert_nil updated.value, "a stored JSON null arrives as a present-and-nil Full value"
        assert_nil entries.delete(entry.public_id, lock_version: updated.lock_version)
        assert_raises(CybrosAgent::Api::NotFound) { entries.fetch(entry.public_id) }
      end

      # ---- the second Agent and the fence ----

      def verify_dedication_fence(workspace_public_id, entry)
        fence_client = CybrosAgent::Client.new(
          base_url: @base_url, credential: connect_fence_agent.access_token
        )

        # Reads pass: the mismatched Agent browses the Workspace and its entries
        # through its steward-derived access.
        seen = fence_client.workspaces.fetch(workspace_public_id)
        assert_equal workspace_public_id, seen.public_id
        fence_entries = fence_client.workspace(workspace_public_id).store_entries
        assert_includes fence_entries.list.items.map(&:public_id), entry.public_id
        assert_equal entry.public_id, fence_entries.fetch(entry.public_id).public_id

        # The dedication filter resolves the caller's own identifier server-side:
        # another agent's dedication is never this agent's.
        assert_empty fence_client.workspaces.list(dedicated_to_current_agent: true).items

        # Every write is fenced with the dedication mismatch.
        fenced_create = assert_raises(CybrosAgent::Api::Forbidden) do
          fence_entries.create(
            namespace: "e2e", key: "fenced", value: { "mine" => true }, idempotency_key: SecureRandom.uuid
          )
        end
        assert_equal "workspace_agent_identifier_mismatch", assert_contract_error(fenced_create.code)
        fenced_update = assert_raises(CybrosAgent::Api::Forbidden) do
          fence_entries.update(entry.public_id, value: { "mine" => true }, lock_version: entry.lock_version)
        end
        assert_equal "workspace_agent_identifier_mismatch", assert_contract_error(fenced_update.code)
        fenced_delete = assert_raises(CybrosAgent::Api::Forbidden) do
          fence_entries.delete(entry.public_id, lock_version: entry.lock_version)
        end
        assert_equal "workspace_agent_identifier_mismatch", assert_contract_error(fenced_delete.code)

        # Owner policy stays server-side: the browsable Agent invoking an
        # owner-only command receives the honest refusal, not the fence code.
        not_owner = assert_raises(CybrosAgent::Api::Forbidden) do
          fence_client.workspace(workspace_public_id).update(name: "not yours", lock_version: seen.lock_version)
        end
        assert_equal "not_workspace_owner", not_owner.code
        fence_client
      end

      # ---- the store's other two hosts ----

      # A store is the client's own current values that no prompt ever reads,
      # and the ROUTE says whose: the Workspace's (above), a conversation's, the
      # acting principal's own. The harness holds no member token of rho's, so
      # the same-steward fence Agent stands in for "rho's own" profile store:
      # decision (12) is observed as Agent-versus-Human under ONE steward — an
      # Agent's profile store is the Agent's, not its steward's.
      def verify_store_hosts(steward_client, workspace_public_id, fence_client)
        workspace = steward_client.workspace(workspace_public_id)

        # The conversation host: the steward (never fenced) opens a conversation
        # in the dedicated Workspace and writes under it. The same (namespace,
        # key) on the Workspace host is a second, independent row — each host's
        # list holds its own and nothing of the other's.
        chat = workspace.conversations.create(title: "Store host", idempotency_key: SecureRandom.uuid)
        conversation_entries = workspace.conversation(chat.public_id).store_entries
        value = { "scratch" => [1, 2, 3] }
        conversation_entry = conversation_entries.create(
          namespace: "e2e", key: "shared-pair", value: value, idempotency_key: SecureRandom.uuid
        ).store_entry
        assert_equal value, conversation_entry.value
        workspace_entry = workspace.store_entries.create(
          namespace: "e2e", key: "shared-pair", value: { "level" => "workspace" }, idempotency_key: SecureRandom.uuid
        ).store_entry
        refute_equal conversation_entry.public_id, workspace_entry.public_id, "one pair, two hosts, two rows"
        conversation_ids = conversation_entries.list.items.map(&:public_id)
        assert_includes conversation_ids, conversation_entry.public_id
        refute_includes conversation_ids, workspace_entry.public_id
        workspace_ids = workspace.store_entries.list.items.map(&:public_id)
        assert_includes workspace_ids, workspace_entry.public_id
        refute_includes workspace_ids, conversation_entry.public_id

        # The fence reaches the conversation host through its Workspace: the
        # mismatched Agent's read passes, its write is the dedication mismatch.
        fence_conversation_entries = fence_client.workspace(workspace_public_id).conversation(chat.public_id).store_entries
        assert_includes fence_conversation_entries.list.items.map(&:public_id), conversation_entry.public_id
        fenced = assert_raises(CybrosAgent::Api::Forbidden) do
          fence_conversation_entries.create(
            namespace: "e2e", key: "fenced", value: { "mine" => true }, idempotency_key: SecureRandom.uuid
          )
        end
        assert_equal "workspace_agent_identifier_mismatch", assert_contract_error(fenced.code)

        # The profile host is per principal and unfenced: the Agent's row is the
        # Agent's, the steward's is the steward's, and neither sees the other's.
        own_key = SecureRandom.uuid
        own = fence_client.profile.store_entries.create(
          namespace: "e2e", key: "own", value: { "agent" => true }, idempotency_key: own_key
        ).store_entry
        assert_equal({ "agent" => true }, own.value)
        refute_includes steward_client.profile.store_entries.list.items.map(&:key), "own",
          "an Agent's profile store is not its steward's"
        steward_own = steward_client.profile.store_entries.create(
          namespace: "e2e", key: "steward-own", value: { "human" => true }, idempotency_key: SecureRandom.uuid
        ).store_entry
        assert_equal({ "human" => true }, steward_own.value)
        agent_keys = fence_client.profile.store_entries.list.items.map(&:key)
        assert_includes agent_keys, "own"
        refute_includes agent_keys, "steward-own", "a steward's profile store is not its Agent's"

        # No receipt is kept for the profile store: the SAME key retried is
        # key_taken, never the replay the Workspace host answered above.
        retried = assert_raises(CybrosAgent::Api::Conflict) do
          fence_client.profile.store_entries.create(
            namespace: "e2e", key: "own", value: { "agent" => true }, idempotency_key: own_key
          )
        end
        assert_equal "key_taken", assert_contract_error(retried.code)

        # A conversation's store leaves with its conversation: once tombstoned,
        # the store route reads as absence like the conversation itself.
        workspace.conversation(chat.public_id).delete
        assert_raises(CybrosAgent::Api::NotFound) { conversation_entries.list }
      end

      def connect_fence_agent
        flow = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
        E2E::DeviceAuthorizationBudget.consume
        authorization = flow.request_authorization(
          agent_identifier: FENCE_AGENT_IDENTIFIER,
          agent_display_name: "E2E fence probe",
          executor_display_name: "E2E fence probe app"
        )
        # A grant no daemon owns: branch A, no runner sentence, nothing to await.
        E2E::Ceremony.confirm(actor: @actor, status: nil, started: {
          "verification_uri_complete" => authorization.verification_uri_complete,
          "user_code" => authorization.user_code,
          "branch" => "agent",
        })
        flow.await_credentials(authorization)
      end

      # ---- the daemon and the steward's browser ----

      # A person's own shape, authored over the member plane and started at
      # once: the named runner on the shell, one tool step, one mock round.
      def author_and_start(workspace_public_id, runner_executor_public_id, tool_step)
        authored = agent_api(:post, "/agent_api/v1/workspaces/#{workspace_public_id}/runs",
          body: { run: {
            default_runner_executor_public_id: runner_executor_public_id,
            steps: [tool_step, { model: { key: "m1", model: { model: "dev/mock-text" }, prompt: "!mock -- report it" } }],
            approval_mode: "bypass",
          } })
        public_id = authored.dig("run", "public_id")
        refute_nil public_id, "nexus answered #{authored.inspect}"
        agent_api(:post, "/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{public_id}/start")
        public_id
      end

      # THE SECOND INSTALL: a fresh RHO_HOME under the same steward, booted, paired and adopted, then
      # stopped — its Profile and its dedicated Workspace are the answer; its home is the caller's to
      # remove. The two `instance.json` ids are distinct and each `rho status` prints its own.
      def pair_a_second_home(steward_client)
        home = Dir.mktmpdir("rho-workspace-e2e-second")
        @second = E2E::RhoDaemon.new(base_url: @base_url, home: home)
        @second.start
        E2E::Ceremony.confirm(actor: @actor, started: @second.start_ceremony, status: -> { @second.status })
        adopted = @second.await("the second install never reported workspace adopted") do
          document = @second.status
          document.dig("workspace", "state") == "adopted" ? document : nil
        end
        profile_public_id = adopted.dig("identity", "user_public_id")
        workspace_public_id = adopted.dig("workspace", "public_id")
        refute_nil profile_public_id
        refute_nil workspace_public_id
        assert_equal "agent", steward_client.workspaces.fetch(workspace_public_id).creator.kind

        first, second = [@home, home].map { |root| instance_id(root) }
        refute_equal first, second, "two homes derive two ids"
        status, = @second.cli("status")
        assert_match(/^instance:  #{second}$/, status, "the second install prints its own instance:\n#{status}")
        @second.stop
        [home, profile_public_id, workspace_public_id]
      end

      # The per-home id rho derived at first boot: 8 lowercase hex characters.
      def instance_id(home)
        id = JSON.parse(File.read(File.join(home, "instance.json"), encoding: Encoding::UTF_8)).fetch("id")
        assert_match(/\A[0-9a-f]{8}\z/, id, "the instance id is 8 lowercase hex characters")
        id
      end

      # THE STEWARD'S DEDICATED ROWS FOR ONE RHO: every home pairs as its own `rho.<instance>` Profile
      # now, so the earlier journeys in a shared world leave their own dedicated Workspaces behind; this
      # rho's is the one its Profile created (the summary names no creator, so the Full projection is
      # read per dedicated row — a handful).
      # EVERY page: this world fills with workspaces as its group's other
      # journeys run, and the dedicated row is not always on the first one
      # (the gate of 2026-09-22 read an empty list under a full world).
      def dedicated_rows(steward_client, creator:)
        summaries = []
        after = nil
        loop do
          page = steward_client.workspaces.list(after: after, limit: 100)
          summaries.concat(page.items)
          after = page.next_after
          break if after.nil?
        end
        summaries.select(&:dedicated).select do |summary|
          steward_client.workspaces.fetch(summary.public_id).creator.public_id == creator
        end
      end

      def await_workspace_state(state)
        @daemon.await("the daemon never reported workspace #{state}") do
          document = @daemon.status
          workspace = document["workspace"]
          flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

          workspace&.fetch("state") == state ? document : nil
        end
      end

      # The shared steward session (E2E::StewardSession) signed in once for
      # this file; each test lands on the dashboard and asserts it — the same
      # assertion the per-test sign-in made, now against the shared session.
      def sign_in_steward
        @actor.visit("/")
        assert @page.has_text?("Dashboard")
      end

      def warn_log(path, label)
        warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path))}" if path && File.file?(path)
      end

      def assert_contract_error(code)
        known = @entries_pack.fetch("error_codes") + @errors_pack.fetch("family_codes")
        assert_includes known, code, "observed error code outside the contract pack's closed lists"
        code
      end
  end
end
