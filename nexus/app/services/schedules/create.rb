module Schedules
  class Create
    def self.call(conversation:, creating_user:, attributes:)
      conversation.with_lock(requires_new: true) do
        next Conversations::Outcome.refused(:not_authorized) unless conversation.writable_by?(creating_user)
        next Conversations::Outcome.refused(conversation.input_refusal) if conversation.input_refusal
        next Conversations::Outcome.refused(:side_conversation) if conversation.side?

        job = Schedule.new(attributes.merge(conversation: conversation, creating_user: creating_user))
        next Conversations::Outcome.invalid(job) unless job.valid?
        inherit_requester_voice(job)
        next Conversations::Outcome.refused(:answerer_not_eligible) unless conversation.answerer_eligible?(job.answering_user)
        next Conversations::Outcome.invalid(job) unless job.reset_clock(DatabaseClock.now)

        job.save!
        Conversations::Outcome.accepted(job)
      end
    end

    def self.inherit_requester_voice(job)
      return if job.speaker_public_id || job.source_run_public_id.nil?

      source = job.conversation.hosted_agent_runs.find_by!(public_id: job.source_run_public_id)
      requester = AgentRuns::CallbackResult.for_loop(source)
      actor = Speaker.find_by(public_id: requester) if requester
      job.speaker_public_id = actor.public_id if actor&.ingress_controlled_by?(job.creating_user)
    end
    private_class_method :inherit_requester_voice
  end
end
