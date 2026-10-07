require "json"

module E2E
  module ToolDiagnosticCapture
    module_function

    def requests(rows)
      rows.map do |request|
        payload = request.fetch("payload")
        tools = payload&.fetch("tools", []) || []
        receipts = request.fetch("receipts").map do |receipt|
          input = receipt["input_tokens"]
          read = receipt["cache_read_tokens"]
          receipt.merge("uncached_input_tokens" => (input && read && [input - read, 0].max))
        end
        request.except("payload", "receipts").merge("receipts" => receipts, "tools" => tools,
          "tool_count" => tools.length, "tool_bytes" => JSON.generate(tools).bytesize,
          "payload_bytes" => (JSON.generate(payload).bytesize if payload), "payload" => payload)
      end
    end
  end
end
