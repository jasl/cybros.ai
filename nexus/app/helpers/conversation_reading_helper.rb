module ConversationReadingHelper
  def conversation_input_refusal(reason)
    t("conversation_reading.refusals.#{reason}", default: [
      :"agent_resources.refusals.#{reason}",
      :"work_console.error.codes.#{reason}",
      reason.to_s.humanize,
    ])
  end
end
