require "rho/state_file"

module Rho
  module IngressTelegram
    # The channel's optional saved credential, separate from operator settings
    # and delivery state. A saved token takes precedence over deployment defaults.
    class TokenFile
      def initialize(home)
        @file = Rho::StateFile.new(File.join(home.root, "telegram", "token.json"))
      end

      def read = (@file.read || {}).fetch("token", "").to_s
      def write(token) = @file.write("token" => token)
      def clear = @file.delete
      def inspect = "#<#{self.class} [REDACTED]>"
    end
  end
end
