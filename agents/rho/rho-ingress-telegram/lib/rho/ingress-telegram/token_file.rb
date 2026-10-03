require "rho/state_file"

module Rho
  module IngressTelegram
    # The channel's optional saved credential, separate from operator settings
    # and delivery state. An explicit environment token still takes precedence.
    class TokenFile
      def initialize(home)
        @file = Rho::StateFile.new(File.join(home.root, "telegram", "token.json"))
      end

      def read = (@file.read || {}).fetch("token", "").to_s
      def write(token) = @file.write("token" => token)
      def inspect = "#<#{self.class} [REDACTED]>"
    end
  end
end
