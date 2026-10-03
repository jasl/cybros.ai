require_relative "contract_fixtures"

module CybrosAgentTest
  module ContractClients
    DeviceFlowTransport = Data.define(:script, :calls) do
      def call(path, method: :get, credential: nil, body: nil, form: nil, params: nil, headers: {},
               timeout:, accept: CybrosAgent::JSON_MEDIA)
        raise "timeout must stay positive" unless timeout.positive?
        raise "machine endpoints are POSTed as forms" unless method == :post

        calls << [path, form.transform_keys(&:to_s)]
        status, headers, body = script.shift
        CybrosAgent::Response.new(status: status, headers: headers || {}, body: body)
      end
    end

    def contract(name)
      CybrosAgentTest::ContractFixtures.pack(name)
    end

    def resolve(reference)
      CybrosAgentTest::ContractFixtures.resolve(reference)
    end

    def api_client(body)
      transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      CybrosAgent::Client.new(
        base_url: "http://example.test",
        credential: "fixture-member-token",
        transport: transport
      )
    end

    def executor_client(body)
      transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      CybrosAgent::ExecutorClient.new(
        base_url: "http://example.test",
        credential: "fixture-executor-token",
        transport: transport
      )
    end

    def platform_client(body)
      transport = CybrosAgentTest::FakeTransport.new([[200, {}, body]])
      CybrosAgent::PlatformClient.new(
        base_url: "http://example.test",
        credential: "fixture-platform-token",
        transport: transport
      )
    end

    def device_flow_client(script)
      transport = DeviceFlowTransport.new(script, [])
      client = CybrosAgent::DeviceFlow::Client.new(
        base_url: "http://example.test",
        transport: transport,
        clock: -> { 0.0 },
        sleeper: ->(_seconds) { }
      )
      [client, transport]
    end


    def frames_through(context, frames)
      client = CybrosAgentTest::FakeRealtimeClient.new(frames)
      [].tap { |items| context.progress(realtime: client).call.each { |item| items << item } }
    end
  end
end
