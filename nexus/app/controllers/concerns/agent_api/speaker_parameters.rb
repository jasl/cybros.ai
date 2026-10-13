module AgentAPI::SpeakerParameters
  private

    # Read the original field so parameter filtering cannot silently discard
    # a malformed selection and replace it with the caller's member voice.
    def speaker_public_id_parameter(value)
      return nil if value.nil?
      raise APIErrors::ParameterInvalid, :speaker_public_id unless ConversationInput.uuid_shaped?(value)

      value.to_s.downcase
    end
end
