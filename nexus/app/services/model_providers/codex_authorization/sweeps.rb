module ModelProviders
  module CodexAuthorization
    # The four durable sweeps: jobs only wake them, so a late or doubled
    # scheduler changes nothing but when. No provider IO — a sweep makes the
    # record agree with the clock.
    module Sweeps
      CREDENTIAL_AMBIGUITY_EXCHANGES = %w[
        device_token_poll code_exchange token_refresh
      ].freeze

      class << self
        # DUE: sessions whose next action has come around. It selects and does
        # not act — the caller claims, because claiming is the transaction that
        # decides, and a sweep that also dispatched would be a second one.
        def due(now: Time.current, limit: 100)
          sessions = ModelProviderOAuthSession
            .nonterminal.where(next_action_at: ..now)
            .order(:next_action_at, :id).limit(limit).to_a
          return sessions if sessions.empty?

          # First take the index-aligned recurring-work window, then apply the
          # cross-table policy predicate inside that budget. The writer permits
          # at most one nonterminal Session per Account/provider lane.
          keys = sessions.map { |session| [session.account_id, session.provider_id] }
          enabled = ModelProviderPolicy
            .where(enabled: true)
            .where(%i[account_id provider_id] => keys)
            .pluck(:account_id, :provider_id)
            .to_h { |key| [key, true] }

          sessions.select { |session| session.device_start? || enabled[[session.account_id, session.provider_id]] }
        end

        # A pending device start whose window has closed; the deadline is the
        # authority, so no retry counter.
        def expire_closed_windows(now: Time.current, limit: 100)
          ModelProviderOAuthSession
            .nonterminal.where(kind: "device_start")
            .where(authorization_deadline_at: ...now)
            .order(:authorization_deadline_at).limit(limit).to_a
            .count do |session|
              session.terminalize(
                state: "expired", outcome: "authorization_deadline_exceeded",
                sanitized_reason: "window_closed", now: now
              )
            end
        end

        # A claim still dispatching past its deadline: the worker is gone
        # with any knowledge of what was sent, so it seals ambiguous, never a retry.
        def seal_stale_dispatches(now: Time.current, limit: 100)
          ModelProviderOAuthTask
            .dispatching.where(deadline_at: ...now)
            .order(:deadline_at, :id).limit(limit).to_a
            .count do |task|
              ModelProviderOAuthSession.transaction do
                # Parent first, the lock order every session/task flow follows;
                # one commit, so a crash cannot leave a spent task under a live refresh.
                session = ModelProviderOAuthSession.lock.find(
                  task.model_provider_oauth_session_id
                )
                settled = task.settle(
                  state: ModelProviderOAuthTask::SPENT,
                  normalized_status: "dispatch_deadline_exceeded",
                  result_kind: "no_response",
                  now: now
                )

                # The parent ends with its dispatch, whatever its kind: sealing already blocks every successor, and a corpse
                # would hold the lane's one session slot. A vanished worker is not a worker reporting uncertainty.
                if settled
                  session.terminalize(
                    state: "failed", outcome: "ambiguous_delivery",
                    sanitized_reason: "dispatch_deadline_exceeded", now: now
                  )
                end
                mark_ambiguous_credential(session, task) if settled
                settled
              end
            end
        end

        # Children first, then the parent; a session is collectable only once
        # every child is terminal, since a dispatching child may still be in the air.
        def collect_terminal_sessions(before:, limit: 100, after_updated_at: nil, after_id: 0)
          window = collection_window(before: before, limit: limit,
            after_updated_at: after_updated_at, after_id: after_id)
          collected = collectable(ids: window.map(&:first)).count do |session|
            ModelProviderOAuthSession.transaction do
              # Through the child's own scope: a `has_many` delete_all nullifies
              # the foreign key, which the not-null column rejects.
              ModelProviderOAuthTask
                .where(model_provider_oauth_session_id: session.id).delete_all
              session.destroy!
            end
          end
          cursor = if window.empty?
            [after_updated_at, after_id]
          else
            id, updated_at = window.last
            [updated_at.iso8601(6), id]
          end
          ::Sweeps::Pass.new(
            counts: { scanned: window.length, collected: collected },
            cursor: cursor, more: limit.positive? && window.length == limit
          )
        end

        private

          # Terminal timestamps never move. Materialize the retention window
          # before checking children so an in-flight request consumes source
          # budget and cannot hold every later session behind it.
          def collection_window(before:, limit:, after_updated_at:, after_id:)
            relation = ModelProviderOAuthSession
              .where.not(state: "pending").where(updated_at: ...before)
            if after_updated_at
              relation = relation.where(
                "(model_provider_oauth_sessions.updated_at, model_provider_oauth_sessions.id) > (?, ?)",
                Time.zone.iso8601(after_updated_at), after_id
              )
            end

            relation.order(:updated_at, :id).limit(limit).pluck(:id, :updated_at)
          end

          def collectable(ids:)
            ModelProviderOAuthSession.where(id: ids).where.not(
              id: ModelProviderOAuthTask.dispatching
                .where(model_provider_oauth_session_id: ids)
                .select(:model_provider_oauth_session_id)
            ).to_a
          end

          def mark_ambiguous_credential(session, task)
            return unless CREDENTIAL_AMBIGUITY_EXCHANGES.include?(task.exchange_kind)
            return if session.source_credential_public_id.nil?

            ModelProviders::MarkReauthorizationRequired.call(
              account: session.account,
              provider_id: session.provider_id,
              lineage_id: session.source_authorization_lineage_id,
              expected_generation: session.source_generation,
              reason: "authorization_ambiguous"
            )
          end
      end
    end
  end
end
