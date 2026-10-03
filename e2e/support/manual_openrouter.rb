require_relative "manual_client"

module E2E
  # THE OPEN-WEIGHT LANE. The compose surface has to work for models far
  # below the frontier — that is where an authoring medium either holds
  # or falls apart, and it is the population most deployments actually
  # run. OpenRouter is the only practical way to reach a dozen of them
  # through one credential.
  #
  # A probe that studies the BROKER names the broker's own model ids here
  # (`microsoft/phi-4`); a bench names catalog refs and routes each one
  # through `ProviderLanes`. Paid, local, opt-in, same gate as every other
  # real-provider probe.
  module ManualOpenRouter
    module_function

    def lane = ProviderLanes.lane("openrouter")

    def validate!(env = ENV) = ManualClient.validate!(env, key_names: [lane.key_name])

    def client(model, env = ENV) = ManualClient.client(lane: lane, model: model, env: env)
  end
end
