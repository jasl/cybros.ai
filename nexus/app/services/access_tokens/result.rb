module AccessTokens
  Result = Data.define(:outcome, :token, :secret) do
    class << self
      def issued(token:, secret:)
        new(outcome: :issued, token: token, secret: secret)
      end

      def invalid_password
        new(outcome: :invalid_password, token: nil, secret: nil)
      end

      def not_issuable
        new(outcome: :not_issuable, token: nil, secret: nil)
      end

      def invalid(token:)
        new(outcome: :invalid, token: token, secret: nil)
      end

      private :new
    end
  end
end
