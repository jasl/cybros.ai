module InferenceRequests
  # A ONE-SHOT A PROVIDER'S CLASSIFIER DECLINED RUNS ONCE MORE on the model
  # its creator's profile declared (`fallback_model`, read live — an agent
  # creator's; a Human declares none). The terminal converger decides it,
  # once, under the aggregate's lock and before the run reads as settled
  # (`InferenceRequest#status` holds `running` until the decision is recorded), so no
  # follower commits a failure that a second execution then retracts.
  #
  # The switch re-reads Create's gates at that moment rather than assuming
  # them from the create — a live aggregate, a workspace the creator may
  # still write in, a creator (and an agent's steward) who still stands —
  # under Create's own authority locks; then resolves the fallback against
  # the caller's own parameters and judges the sealed input against it,
  # since Create normalized that input for the first model alone. The second
  # execution clones the sealed input under the aggregate's key plus its
  # ordinal. A run switches once: only its first execution may, so a
  # fallback declined in turn stands. A content block (`blocked`) never
  # switches. The kernel reads the declared ref and chooses nothing.
  class Fallback
    # The second execution's ordinal on the aggregate's key.
    ORDINAL = 2

    def initialize(inference_request:, invocation:)
      @inference_request = inference_request
      @invocation = invocation
      @locked = false
    end

    # CREATE'S AUTHORITY LOCKS, ahead of the aggregate's (the ladder's order
    # and Create's: the workspace, the creator, an agent's steward), taken
    # only for a declined call that may switch — read off its terminal
    # facts, which are write-once — so an ordinary record takes none. Under
    # them a concurrent authority cut commits either before the re-read
    # (and the switch stands down) or after the mint (and cuts the new
    # execution): never between.
    def lock_authority
      return unless switchable?

      @inference_request.workspace.lock!
      creator = @inference_request.creating_user.lock!
      # Kept on the association, as Create does, so the standing re-read
      # below reads the locked row.
      creator.steward&.lock! if creator.agent_member?
      @locked = true
    end

    # Under the aggregate's and the call's locks: the narrated
    # `model_change` of the switch, or nil for the stand.
    def call
      return unless @locked && first_execution? && !@inference_request.tombstoned? && standing?

      candidate = AgentRuns::ModelFallback.candidate(
        answerer: @inference_request.creating_user, current: @invocation, trigger: :switch,
        reason: AgentRuns::ModelFallback.reason_of(@invocation), category: @invocation.refusal_category
      )
      return if candidate.nil?

      resolved = AgentRuns::ModelFallback.resolve(
        account: @inference_request.account, workload: @inference_request.workload, candidate: candidate,
        configuration: AgentRuns::ModelFallback.chosen_configuration(@invocation)
      )
      return unless resolved.resolved?

      input = @inference_request.content_bodies.find_by!(role: Create::BODY_ROLE)
      return unless takes?(resolved.selection, input)

      mint(resolved.selection, input)
      previous = "#{@invocation.provider_id}/#{@invocation.model_ref}"
      AgentRuns::ModelFallback.log_switch("inference_request=#{@inference_request.public_id}", previous, candidate)
      candidate.narration(previous).fetch("model_change")
    end

    private

      def switchable?
        (@invocation.refused? || @invocation.overloaded?) && @inference_request.creating_user.fallback_model.present? &&
          first_execution?
      end

      # The history bound: the run has had no execution but this one.
      def first_execution?
        !ModelInvocation.where(inference_request_id: @inference_request.id).where.not(id: @invocation.id).exists?
      end

      # Uncached: the query cache would answer from the snapshot taken
      # before the locks, the one moment this re-read must not read.
      def standing?
        ApplicationRecord.uncached { @inference_request.workspace.data_writable_by?(@inference_request.creating_user) }
      end

      # The sealed input as the send will read it, judged against the
      # fallback's selection: its media, its size, its arity, and on a lane
      # that needs every tool round's reasoning back, no tool rounds it did
      # not produce.
      def takes?(selection, input)
        value = Nexus::InputEntries.from(entries: input.entry_payloads, workload: @inference_request.workload)
        ModelSelection::Workloads.accept_normalized_input(
          selection: selection, input: value, uploads: input.request_uploads(@inference_request.workload)
        ).accepted? && AgentRuns::ModelFallback.takes_tool_history?(selection, input)
      end

      # The admission pump picks it up once the converger commits.
      def mint(selection, input)
        fallback = ModelInvocation.create_for_selection(
          selection: selection, inference_request: @inference_request,
          request_options: selection.generation_config.to_h.merge(
            Nexus::PromptCache::RequestKind::FACT => Nexus::PromptCache::RequestKind.stamp("inference_request")
          ),
          internal_creation_key: "#{ModelInvocation.internal_creation_key_for(inference_request: @inference_request)}:#{ORDINAL}"
        )
        ContentBodies::CloneSealed.call(source: input, owner: fallback, role: "request")
        ModelInvocations::AdmitQueuedWorkJob.perform_later
      end
  end
end
