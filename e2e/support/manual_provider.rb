require_relative "manual_client"

module E2E
  # The OpenAI smoke: one streamed reply over the direct API, printed as a compact capture.
  module ManualProvider
    DEFAULT_MODEL = "gpt-6-luna".freeze
    # One short reply; a hang is the only thing this bound has to stop.
    TIMEOUT_SECONDS = 90

    module_function

    def validate!(env = ENV) = ManualClient.validate!(env)

    def model(env = ENV)
      env["E2E_LIVE_MODEL"].to_s.strip.then { |value| value.empty? ? DEFAULT_MODEL : value }
    end

    def client(env = ENV)
      ManualClient.client(lane: ProviderLanes.lane("openai_api"), model: model(env), env: env, timeout: TIMEOUT_SECONDS)
    end
  end
end
