module API
  class APIKeyPresenter
    def self.basic(key)
      {
        public_id: key.public_id,
        name: key.name,
        note: key.note,
        plane: key.credential_plane,
        created_at: key.created_at,
        last_used_at: key.last_used_at,
        revoked_at: key.revoked_at,
        usable: key.member_plane? ? key.usable? : key.executor_usable?,
      }
    end
  end
end
