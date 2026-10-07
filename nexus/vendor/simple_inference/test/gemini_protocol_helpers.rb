module GeminiProtocolHelpers
  private

  def gemini_protocol(adapter:)
    SimpleInference::Protocols::GeminiGenerateContent.new(
      base_url: "https://generativelanguage.googleapis.com", api_key: "secret", adapter: adapter
    )
  end
end
