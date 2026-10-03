module AccessTokens
  # An OAuth-sourced token's revocation cascades to its whole refresh
  # family; a personal token revokes per-row.
  class Revoke
    def self.call(access)
      if access.refresh_token_family
        RefreshTokenFamilies::Revoke.call(access.refresh_token_family)
      else
        result = access.revoke
        ApplicationRecord.current_transaction.after_commit do
          RealtimeConnections::Disconnect.credentials([access])
        end
        result
      end
    end
  end
end
