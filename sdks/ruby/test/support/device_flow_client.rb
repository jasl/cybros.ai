module CybrosAgentTest
  module DeviceFlowClientSupport
    # A transport whose call() replays a scripted queue of responses (or raises
    # a scripted TransportError), recording the requests it received.
    class FakeTransport
      attr_reader :requests

      def initialize(script, on_call: nil)
        @script = script
        @on_call = on_call
        @requests = []
      end

      def call(path, method: :get, credential: nil, body: nil, form: nil, params: nil, headers: {},
               timeout:, accept: CybrosAgent::JSON_MEDIA)
        raise ArgumentError, "machine endpoints are POSTed as forms" unless method == :post

        @requests << [path, form, timeout]
        @on_call&.call
        step = @script.shift
        raise CybrosAgent::TransportError, "boom" if step == :connection_error
        raise CybrosAgent::RequestNotSentError, "boom" if step == :request_not_sent

        CybrosAgent::Response.new(status: step[0], headers: step[1] || {}, body: step[2])
      end
    end

    def build_client(script, on_call: nil, request_timeout: CybrosAgent::DeviceFlow::Client::DEFAULT_REQUEST_TIMEOUT)
      @clock = 0.0
      @transport = FakeTransport.new(script, on_call: on_call)
      @slept = []
      CybrosAgent::DeviceFlow::Client.new(
        base_url: "http://example.test",
        transport: @transport,
        clock: -> { @clock },
        sleeper: ->(seconds) { @slept << seconds; @clock += seconds },
        request_timeout: request_timeout
      )
    end

    AUTH_BODY = {
      "device_code" => "dc-cybros-v1-abc.def", "user_code" => "ABCD-EFGH",
      "verification_uri" => "http://example.test/oauth/device",
      "verification_uri_complete" => "http://example.test/oauth/device?user_code=ABCD-EFGH",
      "interval" => 5, "expires_in" => 900,
    }.freeze

    MEMBER_ONLY_TOKEN_BODY = {
      "access_token" => "sk-cybros-api-v1-x.y", "refresh_token" => "rt-cybros-api-v1-a.b",
      "token_type" => "Bearer", "expires_in" => 1_209_600, "plane" => "member",
    }.freeze
    TOKEN_BODY = MEMBER_ONLY_TOKEN_BODY.merge(
      "executor_access_token" => "sk-cybros-api-v1-transport.z"
    ).freeze
    RUNNER_TOKEN_BODY = MEMBER_ONLY_TOKEN_BODY.merge("plane" => "executor_transport").freeze
    RUNNER_HALF = {
      "access_token" => "sk-cybros-api-v1-runner.z", "refresh_token" => "rt-cybros-api-v1-r.s",
    }.freeze
    COMBINED_TOKEN_BODY = TOKEN_BODY.merge("runner" => RUNNER_HALF).freeze

    private

      def authorization_with(deadline_monotonic:)
        CybrosAgent::DeviceFlow::Authorization.new(
          device_code: "dc-cybros-v1-a.b",
          user_code: "ABCD-EFGH",
          verification_uri: "http://example.test/oauth/device",
          verification_uri_complete: "http://example.test/oauth/device?user_code=ABCD-EFGH",
          interval: 5,
          expires_in: 900,
          deadline_monotonic: deadline_monotonic,
          branch: :agent, executor_kind: "agent_application"
        )
      end
  end
end
