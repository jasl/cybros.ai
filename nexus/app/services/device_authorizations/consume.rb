module DeviceAuthorizations
  # An approved OAuth grant, connected -> consumed as one indivisible result:
  # membership, the one delivery address or the machine, the credential
  # bundle. Any failure leaves nothing behind.
  class Consume
    # RFC 8628 device polling outcomes plus the mint on success. `runner` is
    # the combined grant's second lineage — a transport-led Bundle for the
    # runner — and nil for shapes A and B; it is nested rather than
    # widening RefreshTokens::Bundle because a rotation is per family and
    # would carry a permanently-nil half.
    Result = Data.define(:outcome, *RefreshTokens::Bundle.members, :runner, :agent, :agent_public_id) do
      class << self
        def minted(bundle:, runner: nil, agent: nil, agent_public_id: nil)
          new(outcome: :minted, **bundle.to_h, runner: runner, agent: agent, agent_public_id: agent_public_id)
        end

        def pending = error(:authorization_pending)
        def slow_down = error(:slow_down)
        def expired = error(:expired_token)
        def access_denied = error(:access_denied)
        def invalid_grant = error(:invalid_grant)

        def error(outcome)
          new(
            outcome: outcome,
            access_token: nil,
            executor_access_token: nil,
            refresh_token: nil,
            access_secret: nil,
            executor_access_secret: nil,
            refresh_secret: nil,
            runner: nil,
            agent: nil,
            agent_public_id: nil
          )
        end

        private :new
      end
    end

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(authorization:)
      @authorization = authorization
    end

    def call
      authorization = @authorization.reload

      # Non-connected states never enter the mint transaction; the consumed
      # check precedes TTL so a replay is invalid_grant, not expired.
      case authorization.status
      when "connected" then attempt_mint(authorization)
      when "pending" then classify_pending(authorization)
      when "consumed" then Result.invalid_grant
      when "canceled", "invalidated" then Result.access_denied
      when "expired" then Result.expired
      else Result.invalid_grant
      end
    end

    private

      # A pending grant past its TTL times out on the very next
      # poll rather than waiting for the sweep.
      def classify_pending(authorization)
        if authorization.expires_at <= Time.current
          authorization.materialize_expiry
          Result.expired
        else
          pending_or_slow_down(authorization)
        end
      end

      # A runner is not a principal: the consequence is a machine and
      # its transport credential, nothing more.
      def consume_runner(authorization)
        # Every Runner has a Human manager. Locking that row serializes both ACL
        # scopes for the same (manager, registration_identifier) key; account-wide
        # placement therefore needs no Account-wide coordination lane.
        connector = User.lock.find_by(id: authorization.connected_by_id)
        return invalidate(authorization) unless connector&.active_human_member?
        return invalidate(authorization) unless connector.authority_generation ==
          authorization.connected_by_authority_generation
        return invalidate(authorization) unless human_login_authority_live?(authorization, connector)
        if authorization.selects_account_wide? &&
            !authorization.reconnecting_live_runner? &&
            !connector.admin?
          return invalidate(authorization)
        end

        existing = find_runner(authorization, connector)
        pairing_marker = existing || latest_runner(authorization, connector)
        # The original deadline remains authoritative while the manager and
        # address rows are contended. Check after the last required lock and
        # before any pairing or credential write.
        return expire_connected(authorization) if authorization.expires_at <= Time.current

        return invalidate(authorization) unless authorization.pairing_matches?(pairing_marker)
        return invalidate(authorization) unless runner_half_mintable?(authorization, existing)

        if authorization.mode_login?
          return invalidate(authorization) unless existing

          return consume_login(authorization, connector, executor: existing)
        end

        runner = materialize_runner(authorization, connector, existing)
        lineage = mint_runner_lineage(authorization, runner)
        authorization.record_consumption(
          task_executor: runner,
          access_token: lineage.transport_credential.token,
          refresh_token: lineage.refresh.token
        )
        if authorization.application_connection?
          Result.minted(
            bundle: ApplicationCredentials.call(authorization: authorization, human: connector, runner: runner),
            runner: runner_bundle(lineage)
          )
        else
          Result.minted(bundle: runner_bundle(lineage))
        end
      end

      # The runner half's own refusals, shared by branch B and the combined
      # shape: a live key whose manager's authority is closed, or — the kind
      # is the registration's, frozen at creation like its scope, and the
      # key is kind-blind — a live key of the other kind, which is drift
      # refused the way a forged scope is.
      def runner_half_mintable?(authorization, existing)
        existing.nil? ||
          (existing.connection_authority_open? &&
            existing.executor_kind == authorization.requested_executor_kind)
      end

      # The logical registration identifier re-pairs its one live address in
      # place — stable public id, epoch advance fencing the previous
      # credential — whichever machine kind holds it; a fresh identifier
      # creates a different registration under the REQUESTED kind.
      def find_runner(authorization, connector)
        TaskExecutor.live.registered_as(**runner_finder(authorization, connector)).lock.take
      end

      def latest_runner(authorization, connector)
        TaskExecutor.registered_as(**runner_finder(authorization, connector)).newest_first.lock.first
      end

      def runner_finder(authorization, connector)
        {
          account_id: authorization.account_id,
          registration_identifier: authorization.registration_identifier,
          manager_id: connector.id,
        }
      end

      def materialize_runner(authorization, connector, existing)
        scope = authorization.selected_assignment_scope
        existing&.re_pair(display_name: authorization.runner_display_name) ||
          authorization.account.task_executors.create!(
            executor_kind: authorization.requested_executor_kind,
            display_name: authorization.runner_display_name,
            registration_identifier: authorization.registration_identifier,
            assignment_scope: scope,
            manager: connector
          )
      end

      MintedCredential = Data.define(:token, :secret)
      RunnerLineage = Data.define(:transport_credential, :refresh)
      AgentLineage = Data.define(:member_credential, :transport_credential, :refresh)

      # The runner's family and its one transport credential (transport-led:
      # a machine is no principal). The tail — evidence on the grant, the
      # Bundle — belongs to the caller, so the combined shape can mint this
      # lineage beside the agent's and record ONE consumption.
      def mint_runner_lineage(authorization, runner)
        now = Time.current
        family = authorization.account.refresh_token_families.create!(
          access_token_name: runner_lineage_name(authorization),
          client_id: authorization.client_id,
          device_ip: authorization.request_ip,
          device_user_agent: authorization.request_user_agent,
          task_executor: runner,
          credential_epoch: runner.credential_epoch,
          last_used_at: now
        )
        parts = AccessToken::DIGESTED.mint_parts
        transport = authorization.account.access_tokens.create!(
          name: family.access_token_name,
          source: authorization.authorization_code? ? :oauth_authorization : :oauth_device,
          credential_plane: :executor_transport,
          lookup_id: parts.lookup_id,
          secret_digest: parts.digest,
          expires_at: now + AccessToken::OAUTH_TTL,
          task_executor: runner,
          credential_epoch: runner.credential_epoch,
          refresh_token_family: family
        )
        refresh = RefreshTokens::Issue.call(
          refresh_token_family: family,
          access_token: transport
        )

        RunnerLineage.new(
          transport_credential: MintedCredential.new(token: transport, secret: parts.raw),
          refresh: refresh
        )
      end

      def runner_bundle(lineage)
        RefreshTokens::Bundle.new(
          access_token: nil, executor_access_token: lineage.transport_credential.token,
          refresh_token: lineage.refresh.token,
          access_secret: nil, executor_access_secret: lineage.transport_credential.secret,
          refresh_secret: lineage.refresh.secret
        )
      end

      def runner_lineage_name(authorization)
        kind = authorization.tool_provider_connection? ? "Tools provider" : "Runner"
        "#{kind} connection — #{authorization.runner_display_name}".first(AccessToken::NAME_MAX_LENGTH)
      end

      def invalidate(authorization)
        DeviceAuthorization.invalidate_connected(authorization.id)
        Result.access_denied
      end

      LockedReferences = Data.define(:member, :connector)

      # The single-mint path: lock, recheck the CAS conditions, then the
      # whole consequence or none of it. Shape A and the combined shape A+B
      # share it; the combined shape adds the runner half.
      #
      # THE LOCK ORDER: device_authorizations → users
      # (agent before human) → task_executors, and WITHIN task_executors the
      # agent address is locked explicitly BEFORE the runner row ("kind
      # order"), so both rows are held when the checks run and two combined
      # consumes never cross; `supersede_previous_connection` (an UPDATE on
      # families, rank 7) follows both task_executors locks; the mints come
      # last. The within-table pair is pinned by combined_connection_test's
      # race test.
      #
      # CHECK-BEFORE-WRITE: `next Result.access_denied` inside `with_lock`
      # COMMITS the invalidation, so every check of BOTH halves runs before
      # `materialize_member` — a runner refusal after the member is restored
      # would leave a re-paired member and an advanced agent epoch behind
      # ("any failure leaves nothing behind", the header above). A check that
      # cannot precede a write must refuse by RAISE (rollback), never `next`.
      def attempt_mint(authorization)
        authorization.with_lock do
          # A concurrent terminal transition keeps its public OAuth
          # classification. Consumed replay is the sole invalid_grant state.
          next locked_state_result(authorization) unless authorization.connected?
          next expire_connected(authorization) if authorization.expires_at <= Time.current
          next consume_runner(authorization) if authorization.runner_only_connection?

          references = lock_references(authorization)
          existing = lock_agent_address(references.member)
          pairing_marker = existing ||
            (TaskExecutor.latest_address_for(references.member) if references.member)
          combined = authorization.combined_connection?
          runner_existing = find_runner(authorization, references.connector) if combined
          # The original deadline remains authoritative while authority and
          # address rows are contended. Check after the last required lock and
          # before the first membership, pairing or credential write.
          next expire_connected(authorization) if authorization.expires_at <= Time.current

          unless mintable?(authorization, references, existing, pairing_marker) &&
              (!combined || runner_half_mintable?(authorization, runner_existing))
            # Commit invalidation in this same lock-owning transaction. A
            # queued poll cannot mint between the drift decision and its
            # terminal marker.
            DeviceAuthorization.invalidate_connected(authorization.id)
            next Result.access_denied
          end

          if authorization.mode_login?
            next invalidate(authorization) unless references.member&.active? && existing

            next consume_login(authorization, references.connector, member: references.member, executor: existing)
          end

          member = materialize_member(authorization, references.member, references.connector)
          executor = resolve_executor(authorization, member, existing)
          runner = materialize_runner(authorization, references.connector, runner_existing) if combined
          supersede_previous_connection(member)
          agent = mint_agent_lineage(authorization, member, executor)
          runner_lineage = mint_runner_lineage(authorization, runner) if runner

          # ONE consumption: the evidence pointers are the agent's. The runner
          # family leaves no pointer on the row — it is findable through
          # refresh_token_families.task_executor_id (the recorded asymmetry).
          authorization.record_consumption(
            user: member,
            task_executor: executor,
            access_token: agent.member_credential.token,
            refresh_token: agent.refresh.token
          )
          if authorization.application_connection?
            Result.minted(
              bundle: ApplicationCredentials.call(authorization: authorization, human: references.connector, agent: member),
              agent: agent_bundle(agent),
              runner: (runner_bundle(runner_lineage) if runner_lineage),
              agent_public_id: member.public_id
            )
          else
            Result.minted(
              bundle: agent_bundle(agent),
              runner: (runner_bundle(runner_lineage) if runner_lineage)
            )
          end
        end
      end

      # Agent before human before executor, the edge every multi-row site
      # shares; a create locks its Human. The unique Agent identifier index
      # arbitrates a simultaneous first connection by different Humans.
      def lock_references(authorization)
        member = authorization.user_id &&
          User.lock.find_by(id: authorization.user_id)
        connector = User.lock.find_by(id: authorization.connected_by_id)

        LockedReferences.new(member: member, connector: connector)
      end

      # The profile's live address, locked explicitly here (Connect's own
      # `agent_pairing_marker` shape) so the within-table order above holds;
      # `re_pair`'s `with_lock` re-acquires the row this transaction holds.
      def lock_agent_address(member)
        TaskExecutor.live.addressing(member).lock.first if member
      end

      def locked_state_result(authorization)
        case authorization.status
        when "expired" then Result.expired
        when "canceled", "invalidated" then Result.access_denied
        else Result.invalid_grant
        end
      end

      def expire_connected(authorization)
        authorization.materialize_expiry
        Result.expired
      end

      # Best-effort pacing, an abuse backstop rather than an authority boundary.
      def pending_or_slow_down(authorization)
        now = Time.current
        if authorization.last_polled_at && authorization.last_polled_at > now - authorization.interval
          authorization.update!(
            interval: (authorization.interval + DeviceAuthorization::SLOW_DOWN_STEP)
              .clamp(..DeviceAuthorization::MAX_INTERVAL)
          )
          Result.slow_down
        else
          authorization.update!(last_polled_at: now)
          Result.pending
        end
      end

      # The mapping is re-resolved and must equal the frozen
      # consequence: Consume never outruns current authority, and a
      # drifted Request invalidates instead of minting.
      def mintable?(authorization, references, existing, pairing_marker)
        member = references.member
        connector = references.connector
        return false unless connector&.active_human_member?
        return false unless human_login_authority_live?(authorization, connector)
        return false unless connector.authority_generation ==
          authorization.connected_by_authority_generation
        # A frozen mapping whose row vanished is drift, never a fresh create.
        return false if authorization.user_id && member.nil?
        return false if member && !member.steward_live?
        return false if existing && !existing.connection_authority_open?

        resolved = Consequence.for(authorization, viewer: connector)
        !resolved.bound_elsewhere? && resolved.member&.id == member&.id &&
          (member.nil? || member.authority_generation == authorization.user_authority_generation) &&
          authorization.pairing_matches?(pairing_marker)
      end

      def human_login_authority_live?(authorization, connector)
        return true unless authorization.application_connection?

        identity = connector.identity
        authorization.connected_by_identity_recovery_generation == identity.credential_recovery_generation &&
          !identity.local_recovery_pending? && !identity.password_change_required?
      end

      # A routine browser login proves the existing binding but leaves every
      # running executor and its independent credential lineage untouched.
      def consume_login(authorization, connector, executor:, member: nil)
        bundle = ApplicationCredentials.call(
          authorization: authorization, human: connector, agent: member, runner: (executor unless member)
        )
        authorization.record_consumption(
          user: member, task_executor: executor,
          access_token: bundle.access_token, refresh_token: bundle.refresh_token
        )
        Result.minted(bundle: bundle, agent_public_id: member&.public_id)
      end

      # Membership commits only here; the inputs were validated at request creation, so
      # the writes cannot fail on a mintable Request.
      def materialize_member(authorization, member, connector)
        member ||= authorization.account.users.new(
          kind: :agent,
          role: :member,
          steward: connector,
          agent_identifier: authorization.agent_identifier
        )
        member.restore if member.removed?
        member.display_name = authorization.agent_display_name
        member.save!
        member
      end

      # An Agent is single-instance: a matching address keeps its public id
      # and advances its epoch, fencing the previous credential.
      def resolve_executor(authorization, member, existing)
        existing&.re_pair(
          display_name: authorization.requested_executor_display_name
        ) ||
          member.task_executors.create!(
            account: member.account,
            executor_kind: :agent_application,
            display_name: authorization.requested_executor_display_name
          )
      end

      # Under the member lock, in the users -> executor -> family order
      # Rotate also descends. The superseded lineage goes with the epoch;
      # the address stays, only the steward's revoke ends it.
      def supersede_previous_connection(member)
        member.refresh_token_families.live.each do |family|
          RefreshTokenFamilies::Revoke.call(family)
        end
      end

      # The agent's family and both its credentials; the tail (evidence, the
      # Bundle) is the caller's, as for the runner lineage above.
      def mint_agent_lineage(authorization, member, executor)
        epoch = executor.credential_epoch
        name = lineage_name(authorization)
        now = Time.current
        # User and executor are already locked above. These INSERTs only add
        # key-share edges to those rows and descendants created in this
        # transaction: family → access token → refresh token.
        family = member.refresh_token_families.create!(
          account: member.account,
          access_token_name: name,
          client_id: authorization.client_id,
          device_ip: authorization.request_ip,
          device_user_agent: authorization.request_user_agent,
          task_executor: executor,
          credential_epoch: epoch,
          user_authority_generation: member.authority_generation,
          last_used_at: now
        )

        # One connection is one lineage issuing the whole bundle; the member half
        # stays unbound because that is what the plane means.
        member_credential = mint_credential(
          member: member, family: family, name: name, plane: :member,
          authorization: authorization,
          executor: nil, epoch: nil, now: now
        )
        transport_credential = mint_credential(
          member: member, family: family, name: name, plane: :executor_transport,
          authorization: authorization,
          executor: executor, epoch: epoch, now: now
        )

        # The refresh token pairs with the connection's identity credential;
        # rotation replaces the whole bundle regardless of the pairing.
        refresh = RefreshTokens::Issue.call(
          refresh_token_family: family,
          access_token: member_credential.token,
        )

        AgentLineage.new(
          member_credential: member_credential,
          transport_credential: transport_credential,
          refresh: refresh
        )
      end

      def agent_bundle(lineage)
        RefreshTokens::Bundle.new(
          access_token: lineage.member_credential.token,
          executor_access_token: lineage.transport_credential.token,
          refresh_token: lineage.refresh.token,
          access_secret: lineage.member_credential.secret,
          executor_access_secret: lineage.transport_credential.secret,
          refresh_secret: lineage.refresh.secret
        )
      end

      def mint_credential(member:, family:, name:, plane:, executor:, epoch:, now:, authorization:)
        parts = AccessToken::DIGESTED.mint_parts
        token = member.access_tokens.create!(
          name: name,
          source: authorization.authorization_code? ? :oauth_authorization : :oauth_device,
          credential_plane: plane,
          lookup_id: parts.lookup_id,
          secret_digest: parts.digest,
          expires_at: now + AccessToken::OAUTH_TTL,
          task_executor: executor,
          credential_epoch: epoch,
          user_authority_generation: member.authority_generation,
          refresh_token_family: family
        )

        MintedCredential.new(token: token, secret: parts.raw)
      end

      # Server-owned lineage label, preserved by refresh successors.
      def lineage_name(authorization)
        "Device connection — #{authorization.agent_display_name}".first(AccessToken::NAME_MAX_LENGTH)
      end
  end
end
