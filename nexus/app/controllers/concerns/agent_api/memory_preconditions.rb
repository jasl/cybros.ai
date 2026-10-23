module AgentAPI::MemoryPreconditions
  private

    def memory_collection_precondition(fields)
      value = fields.fetch(:expected_collection_public_id).to_s.downcase
      raise APIErrors::ParameterInvalid, :expected_collection_public_id unless value.match?(MemoryDocuments::Precondition::UUID_FORMAT)

      value
    end

    # Both selectors are required, including explicit nulls for create-only.
    # Missing cannot mean unconditional: background edits carry old snapshots.
    def memory_precondition(fields, allow_absent:)
      MemoryDocuments::Precondition.parse(fields, allow_absent: allow_absent)
    rescue KeyError => error
      raise ActionController::ParameterMissing.new(error.key)
    rescue ArgumentError => error
      raise APIErrors::ParameterInvalid, error.message
    end
end
