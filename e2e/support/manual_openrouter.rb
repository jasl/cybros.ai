require_relative "manual_client"

module E2E
  # A probe that studies the broker names the broker's own model ids here
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
