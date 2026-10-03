module AgentAPI::IngressActorPresenter
  def self.detail(actor)
    { public_id: actor.public_id, kind: actor.kind, channel_key: actor.channel_key,
      external_id: actor.external_id, display_name: actor.display_name }
  end
end
