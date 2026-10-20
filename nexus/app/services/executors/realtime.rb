module Executors
  # Signaling for an already accepted task. Reads project authority; writes
  # replace one bounded handshake under the caller's Run -> Task lock order.
  class Realtime
    def initialize(task, credential:)
      @task = task
      @run = task.run
      @credential = credential
    end

    attr_reader :run

    # No new execution state: all authority is read from the existing owners.
    # This GET projection deliberately takes no locks and never settles a task.
    def projection
      signal = @task.realtime_signal
      reason = execution_refusal
      return view("closed", reason) if reason
      return view("waiting", "offer_required") unless signal
      return view("closed", "claim_changed") unless signal.claim_digest == Digest::SHA256.hexdigest(@task.claim_token.to_s)

      transport = credential(signal.executor_credential_public_id, :refresh_token_family, executor: [:manager, :assignment_agent])
      unless transport&.executor_usable? && transport.executor_id == @task.claimed_by_executor_id &&
          transport.executor.eligible_for?(run.execution_agent, readiness: { transport.executor_id => :ready })
        return view("closed", "executor_credential_revoked")
      end

      member = credential(signal.member_credential_public_id, :refresh_token_family, user: [:identity, :steward]) if signal.member_credential_public_id
      if signal.member_credential_public_id && !member?(member)
        return view("closed", "member_credential_revoked")
      end
      return view("paused", "execution_paused") if run.paused? || Deployments::Maintenance.active?
      return view("waiting", "answer_required", descriptions: true) unless member

      now = Time.current
      limits = [1.0, @task.wall_deadline_at(now)&.-(now), transport.expires_at&.-(now), member.expires_at&.-(now)].compact
      view("active", nil, descriptions: true, max_age_ms: [(limits.min * 1000).floor, 0].max)
    end

    def member?(credential = @credential)
      agent = run.execution_agent
      credential&.usable? && agent && agent.application_owner == credential.user &&
        agent.execution_principal_eligible? && run.writable_by?(agent) && run.writable_by?(credential.user)
    end

    # Caller holds Run then Task. Same-id retries never change the handshake.
    def offer(connection_id:, sdp:, token:, previous_connection_id: nil)
      return :not_claimant unless @credential.executor.runner? && @task.claimed_by?(@credential.executor, token: token)
      return :realtime_unavailable if execution_refusal || run.paused? || !Deployments::Maintenance.admitting?

      old = @task.realtime_signal
      digest = Digest::SHA256.hexdigest(@task.claim_token)
      if old && old.claim_digest == digest
        if old.connection_id == connection_id
          return old.offer_sdp == sdp && old.executor_credential_public_id == @credential.public_id ? :accepted : :signal_conflict
        end
        return :signal_conflict unless previous_connection_id == old.connection_id
      end
      @task.update!(realtime_signal: {
        connection_id: connection_id, claim_digest: digest,
        executor_credential_public_id: @credential.public_id, offer_sdp: sdp,
      })
      :accepted
    end

    def answer(connection_id:, sdp:)
      return :not_authorized unless member?
      signal = @task.realtime_signal
      return :signal_conflict unless signal && signal.connection_id == connection_id
      return :realtime_unavailable unless %w[waiting active].include?(projection.fetch(:status))
      if signal.answer_sdp
        return signal.answer_sdp == sdp && signal.member_credential_public_id == @credential.public_id ? :accepted : :signal_conflict
      end

      @task.update!(realtime_signal: signal.attributes.merge("answer_sdp" => sdp, "member_credential_public_id" => @credential.public_id))
      :accepted
    end

    private

      # The original handshake credential remains the authority. Reuse the
      # caller's request-local record only on an exact match; rotation cannot
      # substitute a new credential for a revoked participant.
      def credential(public_id, *associations)
        if @credential.public_id == public_id
          @credential
        else
          AccessToken.includes(*associations).find_by(public_id: public_id)
        end
      end

      def execution_refusal
        return "execution_ended" if run.tombstoned? || @task.status != "dispatched" ||
          run.canceling? || run.canceled? || Runs::SourceWork.execution_stopped?(run)
        return "deadline_passed" if @task.deadline_passed?
        agent = run.execution_agent
        return "not_authorized" unless agent&.execution_principal_eligible? && run.writable_by?(agent) &&
          run.workspace.data_writable_by?(run.creating_user)

        nil
      end

      def view(status, reason, descriptions: false, max_age_ms: 0)
        signal = @task.realtime_signal
        { status: status, reason: reason, connection_id: signal&.connection_id,
          offer_sdp: (signal&.offer_sdp if descriptions), answer_sdp: (signal&.answer_sdp if descriptions),
          max_age_ms: max_age_ms }
      end
  end
end
