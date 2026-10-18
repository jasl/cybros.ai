module ModelProviders
  module CodexAuthorization
    # The one writer that may create a session; no provider IO. A device
    # start resumes its issuer's pending session unless explicitly restarted; a refresh
    # refuses a competing session; the lane policy lock, not an index, makes one-nonterminal true.
    class AcceptSession
      def self.call(account:, issuing_user:, kind:, provider_id: PROVIDER_ID, restart: false, now: Time.current)
        new(account:, issuing_user:, kind:, provider_id:, restart:, now:).call
      end

      def initialize(account:, issuing_user:, kind:, provider_id:, restart:, now:)
        @account = account
        @issuing_user = issuing_user
        @kind = kind
        @provider_id = provider_id
        @now = now
        @restart = restart
      end

      # No cross-Account guard: the Account is a singleton, so the check
      # would be untestable code that reads like a protection.
      def call
        ModelProviderOAuthSession.transaction do
          policy = lock_policy_lane
          next refuse(:provider_disabled) if policy.nil? || (@kind == "token_refresh" && !policy.enabled?)

          @kind == "device_start" ? accept_device_start : accept_token_refresh
        end
      end

      private

        # A human may connect a disabled provider. Its retained policy row
        # serializes start, successful install, disable and clear; only a
        # completed device authorization enables it. Refresh cannot create it.
        def lock_policy_lane
          if @kind == "device_start"
            ModelProviderConfig.create_or_find_by!(account: @account, provider_id: @provider_id) do |row|
              row.model_overrides = ModelProviderConfig.empty_overrides
            end
          end
          ModelProviderConfig.lock.find_by(
            account_id: @account.id, provider_id: @provider_id
          )
        end

        def accept_device_start
          # First-terminalize, then create: the successor alone may publish a
          # code, so a stale continuation of the predecessor can neither
          # complete it nor install over the replacement.
          previous = current_nonterminal
          if previous && !@restart
            if previous.device_start? && previous.issuing_user_id == @issuing_user.id
              return Result.new(outcome: :accepted, session: previous)
            end
            return refuse(:oauth_session_in_progress)
          end
          supersede(previous)

          credential = current_credential
          Result.new(outcome: :accepted, session: create(
            progress: "accepted", semantic_exchange_kind: "user_code_request",
            # A new device start owns a NEW lineage: it is minting a
            # credential, not continuing one.
            authorization_lineage_id: SecureRandom.uuid,
            # Frozen only as the CAS target for later replacement/ambiguity
            # checks. Its refresh token is never read here.
            **source_triple(credential)
          ))
        end

        # At most one dispatching task per lane. A device start supersedes,
        # so it is the only path that could leave one behind; it settles
        # `spent`, since the bytes may already have reached the provider.
        def supersede(session)
          return if session.nil?

          session.oauth_tasks.dispatching.each do |task|
            task.settle(
              state: ModelProviderOAuthTask::SPENT,
              normalized_status: "superseded", result_kind: "abandoned",
              now: @now
            )
          end
          session.terminalize(
            state: "revoked", outcome: "superseded", sanitized_reason: "replaced_by_device_start",
            now: @now
          )
        end

        def accept_token_refresh
          return refuse(:oauth_session_in_progress) if current_nonterminal

          credential = current_credential
          return refuse(:credential_not_refreshable) unless refreshable?(credential)

          Result.new(outcome: :accepted, session: create(
            progress: "accepted", semantic_exchange_kind: "token_refresh",
            # A refresh CONTINUES a credential, so it copies that credential's
            # lineage exactly rather than minting a new one.
            authorization_lineage_id: credential.authorization_lineage_id,
            **source_triple(credential)
          ))
        end

        def create(**attributes)
          ModelProviderOAuthSession.create!(
            account: @account, issuing_user: @issuing_user, provider_id: @provider_id,
            kind: @kind, state: "pending", semantic_exchange_ordinal: 0,
            # Ready immediately: the first exchange has nothing to wait for.
            next_action_at: @now,
            **attributes
          )
        end

        def current_nonterminal
          ModelProviderOAuthSession
            .nonterminal.where(account_id: @account.id, provider_id: @provider_id).first
        end

        def current_credential
          ModelProviderCredential.find_by(account_id: @account.id, provider_id: @provider_id)
        end

        # About the refresh token, not the access token; a reauthorization
        # mark says a human must act, and rotating around it would erase that.
        def refreshable?(credential)
          return false if credential.nil?
          return false if credential.refresh_secret.blank?
          return false if credential.reauthorization_required?

          true
        end

        # Exact all-or-none. A device start with no current credential freezes
        # three nulls; anything else would name a target that does not exist.
        def source_triple(credential)
          return { source_credential_public_id: nil, source_authorization_lineage_id: nil,
                   source_generation: nil } if credential.nil?

          {
            source_credential_public_id: credential.public_id,
            source_authorization_lineage_id: credential.authorization_lineage_id,
            source_generation: credential.generation,
          }
        end

        def refuse(outcome) = Result.new(outcome: outcome)
    end
  end
end
