module AccessTokens
  # Independent issuance captures the existing authority fences without locks.
  # A later removal, connection replacement or epoch change invalidates the key
  # through ordinary authentication; the secret exists only in this result.
  class IssueAPIKey
    def self.call(...) = new(...).call

    def initialize(user:, name:, note: nil, executor: nil)
      @user = user
      @executor = executor
      @name = name
      @note = note
    end

    def call
      return Result.not_issuable unless issuable?

      parts = AccessToken::DIGESTED.mint_parts
      owner = @executor || @user
      token = owner.access_tokens.build(
        user: @user, name: @name, note: @note, source: :api_key,
        credential_plane: @executor ? :executor_transport : :member,
        lookup_id: parts.lookup_id, secret_digest: parts.digest,
        credential_epoch: @executor&.credential_epoch,
        user_authority_generation: @user&.authority_generation
      )
      if token.save
        Result.issued(token: token, secret: parts.raw)
      else
        Result.invalid(token: token)
      end
    end

    private

      def issuable?
        member_open = @user.nil? ||
          (@user.execution_principal_eligible? && !@user.named_agent?)
        if @executor
          member_open && @executor.connection_authority_open? &&
            @executor.controlling_human.active_human_member?
        else
          @user.present? && member_open
        end
      end
  end
end
