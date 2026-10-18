module Rho
  class Core
    module Persona
      # The Human login owns this document. The Agent's declaration continues
      # to own its separate system_prompt and summarizer slots.
      def persona
        with_platform_client { |client| client.persona.read.to_h }
      end

      def write_persona(content)
        with_platform_client { |client| client.persona.write(content).to_h }
      end

      def reset_persona
        with_platform_client { |client| client.persona.delete }
      end
    end
  end
end
