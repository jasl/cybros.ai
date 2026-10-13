require "securerandom"
require "socket"

module E2E
  module Evals
    # WHAT A TASK'S ENVIRONMENT MAY DEPEND ON, minted once per run: the
    # daemon home (a token the read tool cannot reach lives beside it —
    # `live_exit_long`'s spec seed), the project dir, a free port for a
    # server the fixture ships, a secret no model can guess (the codeword
    # of the ask shape; the exit long's SPEC_TOKEN), and the model the run
    # is on. `environment.rb` is a lambda over one of these; a static
    # `environment/` directory never reads it.
    Seed = Data.define(:home, :project, :port, :secret, :model) do
      def self.mint(home:, project:, model:)
        new(home: home, project: project, port: free_port, secret: SecureRandom.hex(8), model: model)
      end

      def self.free_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end
    end
  end
end
