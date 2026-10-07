module CybrosAgent
  module Platform
    # The authenticated Human's persona; the same PromptDocument assembled
    # for that Human and their Agents, with whole-slot replacement semantics.
    class PersonaContext
      include Api::ConversationProjections

      PATH = "/api/v1/persona".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def read
        shape(Api::PromptDocument, @dispatch.call(PATH), "prompt_document")
      end

      def write(content, role: nil)
        document = { "content" => content }
        document["role"] = role unless role.nil?
        answer = @dispatch.call(PATH, method: :put,
          body: { "prompt_document" => document })
        shape(Api::PromptDocument, answer, "prompt_document")
      end

      def delete
        @dispatch.call(PATH, method: :delete, success: 204)
        nil
      end
    end
  end
end
