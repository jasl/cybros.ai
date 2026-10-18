module Mcp
  # Only a fixed reason crosses back from the remote boundary. Upstream error
  # messages may contain authentication material or arbitrary server content.
  class Error < StandardError
    attr_reader :code, :request_sent

    def initialize(code, request_sent: false)
      @code = code
      @request_sent = request_sent
      super(code.to_s.humanize)
    end
  end
end
