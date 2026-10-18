module RefreshTokenFamilies
  # One application seam for a family authority cut. Persistence stays on the
  # aggregate; the post-commit Action Cable notification closes only member
  # sockets whose exact token came from this family.
  class Revoke
    def self.call(family)
      now = Time.current
      result = family.revoke(now: now)
      # Query after the family fence: a rotation that won its row lock first
      # is now visible, while one queued behind the fence cannot mint.
      member_tokens = family.access_tokens.where(
        credential_plane: :member, revoked_at: nil
      )
      member_tokens = member_tokens.where(expires_at: nil)
        .or(member_tokens.where(expires_at: now..))
        .includes(:user)
        .to_a
      ApplicationRecord.current_transaction.after_commit do
        RealtimeConnections::Disconnect.credentials(member_tokens)
      end
      result
    end
  end
end
