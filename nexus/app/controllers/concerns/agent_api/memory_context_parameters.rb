module AgentAPI::MemoryContextParameters
  private

    def memory_context_parameter(container)
      return nil if container[:memory_context].nil?

      container.expect(memory_context: [bindings: [[:name, :scope, :access, :conversation_public_id]]]).to_h
    end
end
