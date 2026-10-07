module RefreshTokens
  # The refresh_token grant (RFC 9700). One family authority row serializes
  # rotation and provides the immediate reuse/revocation fence; token rows
  # remain bounded evidence rather than copied authority.
  class Rotate
    Result = Data.define(:outcome, *RefreshTokens::Bundle.members) do
      class << self
        def rotated(bundle:)
          new(outcome: :rotated, **bundle.to_h)
        end

        def invalid_grant = error(:invalid_grant)

        def error(outcome)
          new(
            outcome: outcome,
            access_token: nil,
            executor_access_token: nil,
            refresh_token: nil,
            access_secret: nil,
            executor_access_secret: nil,
            refresh_secret: nil
          )
        end

        private :new
      end

      # A rotation is per family and never mints a second lineage: the
      # combined consume's nested runner Bundle has no rotation counterpart
      # (`Consume::Result#runner`), so the token body's reader asks, and a
      # rotation answers none — a predicate, never a nil-carrying member.
      def runner = nil
      def agent = nil
      def agent_public_id = nil
    end

    LockedReferences = Data.define(
      :target_user,
      :authority_users,
      :task_executor
    )
    private_constant :LockedReferences

    class << self
      def call(...)
        new(...).call
      end
    end

    def initialize(presented:)
      @presented = presented
    end

    def call
      ApplicationRecord.transaction do
        # The global lock order, so a rotation racing a supersession queues instead of
        # deadlocking. The unlocked family read is sound: the binding columns are
        # attr_readonly, and everything mutable is rechecked.
        unlocked = RefreshTokenFamily.find_by(id: @presented.refresh_token_family_id)
        return Result.invalid_grant if unlocked.nil?

        references = lock_references(
          target_user_id: unlocked.user_id,
          task_executor_id: unlocked.task_executor_id
        )

        # One owner-row lock is the family winner rule: a rotation cannot mint
        # after a concurrent reuse/revocation fence commits. Re-found under
        # lock — the row may have been revoked or reaped while we queued.
        family = RefreshTokenFamily.lock.find_by(id: unlocked.id)
        token = family && RefreshToken.lock.find_by(
          id: @presented.id,
          refresh_token_family_id: family.id
        )

        if !token
          Result.invalid_grant
        elsif token.replayable_evidence?
          RefreshTokenFamilies::Revoke.call(family)
          Result.invalid_grant
        elsif !token.current?
          Result.invalid_grant
        else
          rotate(token, family, references)
        end
      end
    end

    private

      MintedCredential = Data.define(:token, :secret)

      # The authority order before a multi-FK insert, so PostgreSQL cannot
      # choose a conflicting implicit-FK order; an identity-less issuance
      # locks its address alone.
      def lock_references(target_user_id:, task_executor_id:)
        target_user = User.lock.find_by(id: target_user_id) if target_user_id
        # A named target whose row vanished has no authority left to issue
        # under, and nothing below it may be locked on its behalf.
        if target_user_id && target_user.nil?
          return LockedReferences.new(
            target_user: nil,
            authority_users: {},
            task_executor: nil
          )
        end

        authority_ids = [target_user&.steward_id].compact - [target_user&.id]
        authority_users = User.lock
          .where(id: authority_ids)
          .order(:id)
          .index_by(&:id)
        task_executor = TaskExecutor.lock.find_by(id: task_executor_id) if task_executor_id

        LockedReferences.new(
          target_user: target_user,
          authority_users: authority_users,
          task_executor: task_executor
        )
      end

      def rotate(token, family, references)
        now = Time.current
        return Result.invalid_grant unless rotation_acceptable?(
          family,
          references,
          now: now
        )
        member = references.target_user
        executor = references.task_executor
        # Rotation reissues every plane the lineage originally issued; a
        # dead member authority reissues the transport half alone rather
        # than a token guaranteed to 401.
        member_credential = if family.user_id && member_authority_live?(family, references)
          mint_credential(
            family: family, issuer: member, now: now,
            plane: family.human_connection? ? :platform : :member, executor: nil, epoch: nil
          )
        end
        transport_credential = if family.task_executor_id
          mint_credential(
            family: family, issuer: member || family.account, now: now,
            plane: :executor_transport, executor: executor,
            epoch: family.credential_epoch
          )
        end
        # The successor pairs with the connection's leading credential — the
        # member plane, or the transport plane when that is the whole bundle.
        access_token = (member_credential || transport_credential).token

        # Mark the predecessor first so the partial unique index permits the
        # successor; the family lock makes this a single serialized handoff.
        token.update!(consumed_at: now)
        successor = RefreshTokens::Issue.call(
          refresh_token_family: family,
          access_token: access_token
        )
        token.update!(superseded_by: successor.token)
        family.update!(last_used_at: now)
        # A rotation is the one stamping edge the executor chokepoint
        # cannot see, or an unattended daemon reads "last seen" frozen at
        # connect time.
        references.task_executor&.refresh_last_seen_at(
          expected_epoch: family.credential_epoch
        )

        bundle = RefreshTokens::Bundle.new(
          access_token: member_credential&.token,
          executor_access_token: transport_credential&.token,
          refresh_token: successor.token,
          access_secret: member_credential&.secret,
          executor_access_secret: transport_credential&.secret,
          refresh_secret: successor.secret
        )
        Result.rotated(bundle: bundle)
      end

      # A member credential hangs off its member; a runner's transport
      # credential has no owning member at all, so the Account holds it
      # exactly as the runner consume minted it.
      def mint_credential(family:, issuer:, now:, plane:, executor:, epoch:)
        parts = AccessToken::DIGESTED.mint_parts
        token = issuer.access_tokens.create!(
          name: family.access_token_name,
          source: :oauth_refresh,
          credential_plane: plane,
          lookup_id: parts.lookup_id,
          secret_digest: parts.digest,
          expires_at: now + AccessToken::OAUTH_TTL,
          task_executor: executor,
          credential_epoch: epoch,
          user_authority_generation: family.user_authority_generation,
          identity_recovery_generation: family.identity_recovery_generation,
          refresh_token_family: family
        )

        MintedCredential.new(token: token, secret: parts.raw)
      end

      # Mirrors RefreshTokenFamily#rotation_acceptable? over the locked rows:
      # the family fence, then whatever authority the lineage actually names.
      def rotation_acceptable?(family, references, now:)
        !family.revoked? &&
          family.within_lifetime?(now: now) &&
          principal_acceptable?(family, references.target_user) &&
          authority_acceptable?(family, references)
      end

      # An identity-less runner lineage's address is its entire authority;
      # the member half drops out rather than failing closed.
      def principal_acceptable?(family, member)
        return true unless family.user_id

        family.human_connection? ? member&.human? : member&.agent_member?
      end

      # Exactly the predicate AccessToken#usable? applies to a member
      # credential, evaluated over the rows this rotation already locked.
      def member_authority_live?(family, references)
        member = references.target_user
        return family.human_authority_live?(member) if family.human_connection?

        steward = member && references.authority_users[member.steward_id]

        member&.active? &&
          family.user_authority_generation == member.authority_generation &&
          (!member.agent_member? ||
            (steward&.active? &&
              member.applied_steward_shutdown_generation ==
                steward.managed_resource_shutdown_generation))
      end

      # Every lineage is executor-bound, so the address is the whole check,
      # asked of the locked executor row rather than of
      # `family.rotation_acceptable?`, which would reload outside the lock.
      def authority_acceptable?(family, references)
        if family.human_connection?
          family.human_authority_live?(references.target_user)
        else
          references.task_executor&.transport_authorized_at?(family.credential_epoch)
        end
      end
  end
end
