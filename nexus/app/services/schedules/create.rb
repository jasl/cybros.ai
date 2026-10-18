module Schedules
  class Create
    def self.call(conversation:, creating_user:, attributes:)
      conversation.with_lock(requires_new: true) do
        create_locked(conversation: conversation, creating_user: creating_user, attributes: attributes)
      end
    end

    # Caller holds the conversation arbiter; kernel tools couple this write to their settlement.
    def self.create_locked(conversation:, creating_user:, attributes:)
      result = prepare(conversation: conversation, creating_user: creating_user, attributes: attributes)
      if result.accepted?
        result.value.save!
      end
      result
    end

    # The browser can inspect this candidate without accepting work. Creation
    # prepares it again under the parent arbiter, using the submission-time clock.
    def self.prepare(conversation:, creating_user:, attributes:, now: nil)
      return Conversations::Outcome.refused(:not_authorized) unless conversation.writable_by?(creating_user)
      return Conversations::Outcome.refused(conversation.input_refusal) if conversation.input_refusal
      return Conversations::Outcome.refused(:side_conversation) if conversation.side?

      job = Schedule.new(attributes.merge(conversation: conversation, creating_user: creating_user))
      job.answering_user ||= conversation.answering_user
      job.agent_configuration ||= Intent.declaration(conversation, answerer: job.answering_user)
      job.model_selection ||= if Conversations::AnswerEngine.captured?(conversation, addressee: job.answering_user)
        conversation.model_selection
      end
      job.model_selection ||= ModelSelectionIntent.default("#{job.provider_id}/#{job.model_ref}")
      job.fallback_models ||= job.agent_configuration&.fallback_models || []
      return Conversations::Outcome.invalid(job) unless job.valid?
      inherit_requester_voice(job)
      return Conversations::Outcome.refused(:answerer_not_eligible) unless conversation.answerer_eligible?(job.answering_user)
      return Conversations::Outcome.invalid(job) unless job.reset_clock(now || DatabaseClock.now)

      Conversations::Outcome.accepted(job)
    end

    def self.inherit_requester_voice(job)
      return if job.speaker_public_id || job.source_run_public_id.nil?

      source = job.conversation.hosted_runs.find_by!(public_id: job.source_run_public_id)
      requester = Runs::CallbackResult.for_loop(source)
      actor = Speaker.find_by(public_id: requester) if requester
      job.speaker_public_id = actor.public_id if actor&.ingress_controlled_by?(job.creating_user)
    end
    private_class_method :inherit_requester_voice
  end
end
