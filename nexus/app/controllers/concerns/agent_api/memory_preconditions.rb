module AgentAPI::MemoryPreconditions
  private

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
