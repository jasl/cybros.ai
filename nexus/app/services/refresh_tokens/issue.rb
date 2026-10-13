module RefreshTokens
  # Creates one refresh-token evidence row and reveals its raw secret to the
  # calling credential workflow. The caller owns any transaction and locks.
  class Issue
    Result = Data.define(:token, :secret)

    class << self
      def call(refresh_token_family:, access_token:)
        parts = RefreshToken::DIGESTED.mint_parts
        token = refresh_token_family.refresh_tokens.create!(
          account: refresh_token_family.account,
          user: refresh_token_family.user,
          access_token: access_token,
          lookup_id: parts.lookup_id,
          secret_digest: parts.digest
        )

        Result.new(token: token, secret: parts.raw)
      end
    end
  end
end
