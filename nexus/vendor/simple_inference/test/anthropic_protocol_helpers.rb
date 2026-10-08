module AnthropicProtocolHelpers
  private

  def exploding_protocol
    adapter =
      Class.new(SimpleInference::HTTPAdapter) do
        def call(_env)
          raise "prepare must not touch the adapter"
        end

        def call_stream(_env)
          raise "prepare must not touch the adapter"
        end
      end.new

    SimpleInference::Protocols::AnthropicMessages.new(
      base_url: "https://api.anthropic.com",
      api_key: "sk-ant-secret",
      adapter: adapter
    )
  end

  def capturing_adapter
    Class.new(SimpleInference::HTTPAdapter) do
      attr_reader :last_request

      def call(env)
        @last_request = env
        {
          status: 200,
          headers: { "content-type" => "application/json" },
          body: JSON.generate(
            id: "msg_capture",
            content: [{ type: "text", text: "ok" }],
            stop_reason: "end_turn",
            usage: { input_tokens: 1, output_tokens: 1 }
          ),
        }
      end
    end.new
  end
end
