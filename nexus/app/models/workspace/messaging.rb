module Workspace::Messaging
  extend ActiveSupport::Concern

  included do
    attribute :messaging_policy, Workspace::MessagingPolicy.to_type,
      default: -> { Workspace::MessagingPolicy.new }

    validates :messaging_policy, store_model: true
    # The ordinary policy request bound, measured on the stored document.
    validates :messaging_policy_document, bounded_json: { bound: :envelope_bound }
    validate :messaging_policy_names_account_agents, if: :will_save_change_to_messaging_policy?
  end

  # Resolved profiles only. Access, lifecycle and accepted-work recovery have
  # their own owners; only the recipient's policy decides who may contact it.
  def messaging_allowed?(sender:, recipient:)
    if sender.public_id == recipient.public_id
      true
    else
      policy = messaging_policy.agents.find { |entry| entry.agent_public_id == recipient.public_id }
      policy.nil? || policy.mode == "public" || policy.allowed_sender_public_ids.include?(sender.public_id)
    end
  end

  private

    def messaging_policy_document
      messaging_policy&.as_json
    end

    # These are identity references, not cached eligibility. Removal or access
    # changes retain the policy; their ordinary admission gates still apply.
    def messaging_policy_names_account_agents
      return if errors[:messaging_policy].any? || errors[:messaging_policy_document].any?

      public_ids = messaging_policy.agents.flat_map do |entry|
        [entry.agent_public_id, *entry.allowed_sender_public_ids]
      end.uniq
      known = account.users.members.where(kind: :agent, public_id: public_ids).pluck(:public_id)
      if known.length != public_ids.length
        errors.add(:messaging_policy, :invalid)
      end
    end
end
