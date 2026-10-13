module InferenceRequests
  # Re-asks one-shot work on its next captured route. Authority and input
  # are checked again under Create's lock order; prior executions remain
  # sealed, and their ordinals bound the finite recovery chain.
  class Fallback
    attr_reader :skips

    def initialize(inference_request:, invocation:)
      @inference_request = inference_request
      @invocation = invocation
      @locked = false
      @skips = []
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
      return unless @locked && !newer_execution? && !@inference_request.tombstoned? && standing?

      input = @inference_request.content_bodies.find_by!(role: Create::BODY_ROLE)
      resolved = AgentRuns::ModelFallback.recover(
        account: @inference_request.account, workload: @inference_request.workload,
        current: @invocation, owner: @inference_request,
        configuration: AgentRuns::ModelFallback.chosen_configuration(@invocation), request_body: input,
        excluded: @inference_request.model_invocations.pluck(:provider_id, :model_ref).map { |provider, model| "#{provider}/#{model}" }
      )
      @skips = resolved.skips
      return unless resolved.resolved?

      candidate = AgentRuns::ModelFallback.from_selection(resolved.selection,
        reason: AgentRuns::ModelFallback.reason_of(@invocation), category: @invocation.refusal_category)

      mint(resolved.selection, input)
      previous = "#{@invocation.provider_id}/#{@invocation.model_ref}"
      AgentRuns::ModelFallback.log_switch("inference_request=#{@inference_request.public_id}", previous, candidate)
      candidate.narration(previous).fetch("model_change")
    end

    private

      def switchable?
        @invocation.recovery_eligible? && @inference_request.fallback_models.any? && !newer_execution?
      end

      def newer_execution?
        ModelInvocation.where(inference_request_id: @inference_request.id).where("id > ?", @invocation.id).exists?
      end

      # Uncached: the query cache would answer from the snapshot taken
      # before the locks, the one moment this re-read must not read.
      def standing?
        ApplicationRecord.uncached { @inference_request.workspace.data_writable_by?(@inference_request.creating_user) }
      end

      # The admission pump picks it up once the converger commits.
      def mint(selection, input)
        ordinal = @inference_request.model_invocations.count + 1
        fallback = ModelInvocation.create_for_selection(
          selection: selection, inference_request: @inference_request,
          request_options: selection.generation_config.to_h.merge(
            Nexus::PromptCache::RequestKind::FACT => Nexus::PromptCache::RequestKind.stamp("inference_request")
          ),
          internal_creation_key: "#{ModelInvocation.internal_creation_key_for(inference_request: @inference_request)}:#{ordinal}"
        )
        ContentBodies::CloneSealed.call(source: input, owner: fallback, role: "request")
        ModelInvocations::AdmitQueuedWorkJob.perform_later
      end
  end
end
