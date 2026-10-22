# The steward's connection verbs: a human owns the programs they
# connected, so ending one's access is a member command, never an
# administrator's.
module User::Connections
  # A console-created program has the same logical identity as a connected one.
  # Its opaque registration key is generated here, never chosen by a person.
  def build_agent(display_name:)
    stewarded_agents.build(account: account, kind: :agent, role: :member,
      display_name: display_name, agent_identifier: SecureRandom.uuid_v7)
  end

  # The one place the address dies with the connection — the human said "stop",
  # not "this moved". The profile lock is Consume's, so the race is ordered; lock
  # order user -> executor -> family.
  def revoke_connection
    with_lock do
      revoke_member_credentials
      Executor.address_for(self)&.revoke
      refresh_token_families.live.each(&:revoke)
    end
    :revoked
  end

  # The caller holds this User's connection lock. The same generation fences
  # every member credential, including keys without a refresh lineage.
  def revoke_member_credentials
    update!(authority_generation: authority_generation + 1)
  end
end
