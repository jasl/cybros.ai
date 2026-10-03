# The steward's connection verbs: a human owns the programs they
# connected, so ending one's access is a member command, never an
# administrator's.
module User::Connections
  # The one place the address dies with the connection — the human said "stop",
  # not "this moved". The profile lock is Consume's, so the race is ordered; lock
  # order user -> executor -> family.
  def revoke_connection
    with_lock do
      TaskExecutor.address_for(self)&.revoke
      refresh_token_families.live.each(&:revoke)
    end
    :revoked
  end
end
