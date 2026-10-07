module Schedule::InputIntent
  extend ActiveSupport::Concern

  included do
    validates :configuration, bounded_json: { bound: :envelope_bound, shape: Hash }
    validates :tool_names, bounded_json: { bound: :envelope_bound, shape: Array }, allow_nil: true
    validate :ordinary_input_policy, if: :input_policy_changed?
    validate :speaker_belongs_to_creator, if: -> { new_record? || speaker_public_id_changed? }
  end

  private

    def input_policy_changed?
      new_record? || %w[answering_user_id configuration tool_names approval_mode].any? { |key| will_save_change_to_attribute?(key) }
    end

    def ordinary_input_policy
      return unless conversation && answering_user && creating_user

      # Validate the input model's narrowing rules without attaching a draft
      # to the parent's collection or creating an input or Speaker.
      draft = ConversationInput.new(host: conversation,
        authoring_user: creating_user, answering_user: answering_user,
        kind: "direct_reply", role: "user", delivery_mode: "queue", context_mode: "assembled",
        queue_position: 0, request_options: configuration, tool_names: tool_names, approval_mode: approval_mode
      )
      draft.valid?
      draft.errors.each do |error|
        next unless %i[request_options tool_names approval_mode].include?(error.attribute)

        attribute = error.attribute == :request_options ? :configuration : error.attribute
        errors.add(attribute, error.type, **error.options)
      end
    end

    def speaker_belongs_to_creator
      return if speaker_public_id.nil? || creating_user.nil?

      actor = Speaker.find_by(account_id: account_id, public_id: speaker_public_id)
      errors.add(:speaker_public_id, :invalid) unless actor&.ingress_controlled_by?(creating_user)
    end
end
