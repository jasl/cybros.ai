module OneShots
  # A ONE-SHOT A PROVIDER'S CLASSIFIER DECLINED RUNS ONCE MORE on the model
  # its creator's profile declared (`fallback_model`, read live — an agent
  # creator's; a Human declares none). The terminal converger decides it,
  # once, under the aggregate's lock and before the run reads as settled
  # (`OneShot#status` holds `running` until the decision is recorded), so no
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

    def initialize(one_shot:, invocation:)
      @one_shot = one_shot
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

      @one_shot.workspace.lock!
      creator = @one_shot.creating_user.lock!
      # Kept on the association, as Create does, so the standing re-read
      # below reads the locked row.
      creator.steward&.lock! if creator.agent_member?
      @locked = true
    end

    # Under the aggregate's and the call's locks: the narrated
    # `model_change` of the switch, or nil for the stand.
    def call
      return unless @locked && first_execution? && !@one_shot.tombstoned? && standing?

      candidate = AgentLoops::ModelFallback.candidate(
        answerer: @one_shot.creating_user, current: @invocation, trigger: :switch,
        reason: AgentLoops::ModelFallback.reason_of(@invocation), category: @invocation.refusal_category
      )
      return if candidate.nil?

      resolved = AgentLoops::ModelFallback.resolve(
        account: @one_shot.account, workload: @one_shot.workload, candidate: candidate,
        configuration: AgentLoops::ModelFallback.chosen_configuration(@invocation)
      )
      return unless resolved.resolved?

      input = @one_shot.content_bodies.find_by!(role: Create::BODY_ROLE)
      return unless takes?(resolved.selection, input)

      mint(resolved.selection, input)
      previous = "#{@invocation.provider_id}/#{@invocation.model_ref}"
      AgentLoops::ModelFallback.log_switch("one_shot=#{@one_shot.public_id}", previous, candidate)
      candidate.narration(previous).fetch("model_change")
    end

    private

      def switchable?
        (@invocation.refused? || @invocation.overloaded?) && @one_shot.creating_user.fallback_model.present? &&
          first_execution?
      end

      # The history bound: the run has had no execution but this one.
      def first_execution?
        !ModelInvocation.where(one_shot_id: @one_shot.id).where.not(id: @invocation.id).exists?
      end

      # Uncached: the query cache would answer from the snapshot taken
      # before the locks, the one moment this re-read must not read.
      def standing?
        ApplicationRecord.uncached { @one_shot.workspace.data_writable_by?(@one_shot.creating_user) }
      end

      # The sealed input as the send will read it, judged against the
      # fallback's selection: its media, its size, its arity, and on a lane
      # that needs every tool round's reasoning back, no tool rounds it did
      # not produce.
      def takes?(selection, input)
        value = Nexus::InputEntries.from(entries: input.entry_payloads, workload: @one_shot.workload)
        ModelSelection::Workloads.accept_normalized_input(
          selection: selection, input: value, uploads: input.request_uploads(@one_shot.workload)
        ).accepted? && AgentLoops::ModelFallback.takes_tool_history?(selection, input)
      end

      # The admission pump picks it up once the converger commits.
      def mint(selection, input)
        fallback = ModelInvocation.create_for_selection(
          selection: selection, one_shot: @one_shot,
          request_options: selection.generation_config.to_h.merge(
            Nexus::PromptCache::RequestKind::FACT => Nexus::PromptCache::RequestKind.stamp("one_shot")
          ),
          internal_creation_key: "#{ModelInvocation.internal_creation_key_for(one_shot: @one_shot)}:#{ORDINAL}"
        )
        ContentBodies::CloneSealed.call(source: input, owner: fallback, role: "request")
        ModelInvocations::AdmitQueuedWorkJob.perform_later
      end
  end
end
