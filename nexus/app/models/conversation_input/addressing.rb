# WHO THIS TURN IS BETWEEN, and who admits it: the author and the ADDRESSEE
# — the host's answerer unless the door named another — under the ONE rule
# the estimate shares (`Conversations::TurnPrincipals`), the origin a
# caller's row derives from its author, and the host's own refusal on the
# row.
module ConversationInput::Addressing
  extend ActiveSupport::Concern

  included do
    validate :steering_target_is_local
    validate :host_admits_the_input, on: :create
    validate :speaker_and_author_share_the_account

    before_validation :derive_origin_from_author, on: :create
  end

  # Whose standing declaration the reply runs under (`declaring_profile`),
  # whether it goes verbatim (`raw?`), the effective word the loop row
  # records, and the block order it compiles under. The input's author is
  # the speaker; whose engine answers is the row's own resolved fact.
  def principals = ConversationTurn::Principals.new(author: authoring_user, answerer: answering_user)
  def declaring_profile = principals.declaring_profile
  def raw? = principals.raw?(context_mode)
  def effective_prompt_mechanism = principals.prompt_mechanism(context_mode)
  def assembly_template = principals.template

  private

    # A caller's word is its author's kind (`human` → `person`); a
    # writer's explicit word — the kernel's own — wins.
    def derive_origin_from_author
      return if origin.present? || authoring_user.nil?

      self.origin = authoring_user.human? ? "person" : "agent"
    end

    # The host's own refusal, on the row: an archived conversation refuses
    # a principal's mail but admits the kernel's own, since archive never
    # blocks an in-flight round — keyed on the kernel SET, never the
    # sender stamp a peer's `send` also carries; absence seals even for
    # the kernel.
    def host_admits_the_input
      refusal = host&.input_refusal
      return if refusal.nil?
      return if refusal == :conversation_archived && kernel_origin?

      errors.add(:host, refusal)
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
