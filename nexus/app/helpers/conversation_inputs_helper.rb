module ConversationInputsHelper
  def conversation_input_cancellable?(input)
    !input.kernel_origin? && Conversations::Inputs::Update::EDITABLE_STATES.include?(input.state)
  end
end
