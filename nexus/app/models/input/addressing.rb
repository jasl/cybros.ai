# WHO THIS TURN IS BETWEEN, and who admits it: the author and the ADDRESSEE
# — the host's answerer unless the door named another — under the ONE rule
# the estimate shares (`Conversations::TurnPrincipals`), the origin a
# caller's row derives from its author, and the host's own refusal on the
# row.
module Input::Addressing
  extend ActiveSupport::Concern

  included do
    validate :steering_target_is_local
    validate :host_admits_the_input, on: :create
    validate :speaker_and_author_share_the_account

    before_validation :derive_origin_from_author, on: :create
  end

  # Whose standing declaration the reply runs under (`execution_agent`),
  # whether it goes verbatim (`raw?`), the effective word the Run row
  # records, and the block order it compiles under. The input's author is
  # the speaker; whose engine answers is the row's own resolved fact.
  def principals = Turn::Principals.new(author: authoring_user, answerer: answering_user, declaration: agent_configuration)
  def execution_agent = principals.execution_agent
  def raw? = principals.raw?(context_mode)
  def effective_prompt_mechanism = principals.prompt_mechanism(context_mode)
  def assembly_template = principals.template

  def host_refusal
    refusal = host&.input_refusal
    return refusal unless refusal == :conversation_archived
    return if kernel_origin?
    return if steering? && expected_steering_run_public_id
    return if host.hosts_turns? && host.spawn_brief_from?(
      run_public_id: sender_run_public_id, task_key: sender_task_key, answerer: answering_user
    )

    refusal
  end

  private

    # A caller's word is its author's kind (`human` → `person`); a
    # writer's explicit word — the kernel's own — wins.
    def derive_origin_from_author
      return if origin.present? || authoring_user.nil?

      self.origin = authoring_user.human? ? "person" : "agent"
    end

    def host_admits_the_input
      errors.add(:host, host_refusal) if host_refusal
    end

    def steering_target_is_local
      return if steering_target_turn.nil?
      return if steering_target_turn.conversation == host

      errors.add(:steering_target_turn, :invalid)
    end

    def speaker_and_author_share_the_account
      if speaker && speaker.account_id != account_id
        errors.add(:speaker, :invalid)
      end
      if authoring_user && authoring_user.account_id != account_id
        errors.add(:authoring_user, :invalid)
      end
      if answering_user && answering_user.account_id != account_id
        errors.add(:answering_user, :invalid)
      end
    end
end
