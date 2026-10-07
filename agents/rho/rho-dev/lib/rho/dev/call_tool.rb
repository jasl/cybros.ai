require "json"

module Rho
  module Dev
    # THE RELAY REQUEST: a tool call addressed to one runner
    # as a one-task run, waited for, printed whole — `--timeout` is the
    # step's own clock and beats the runner's announced park.
    module CallTool
      # `rho call_tool`'s default deadline: the step's own clock in
      # milliseconds, the shape of a `ps`/`logs`/`fetch`-sized read.
      TOOL_CALL_TIMEOUT_MS = 30_000

      def self.register(api)
        api.register_command("call_tool", usage: "call_tool RUNNER TOOL [INPUT_JSON]",
          description: "Ask one runner to run a tool it announced (a file's bytes, a process's log) and " \
                       "print the answer: a one-task run created, started and read; a request that " \
                       "does not complete is stopped behind its error",
          options: {
            timeout: { type: :numeric, default: TOOL_CALL_TIMEOUT_MS,
                       desc: "The request's own deadline in milliseconds (beats the tool's announced park)" },
          }, &method(:call_tool))
      end

      class << self
        # `rho call_tool RUNNER TOOL [INPUT_JSON]` — the daemon authors the
        # one-task run on that runner with the rules `do` authors, starts
        # it, waits for the task and answers it whole; this prints the task
        # the way `rho task` does, then its `content` — a text block as its
        # text, a `resource_link` as its line with the id `rho fetch` takes
        # — and fails the verb when the request did not complete: the
        # error line above is the answer.
        def call_tool(cli, (runner, tool, input_json), options)
          raise Rho::Error, "call_tool needs RUNNER TOOL [INPUT_JSON]" if runner.to_s.empty? || tool.to_s.empty?

          input = tool_input(input_json)
          timeout_ms = Integer(options.fetch(:timeout, TOOL_CALL_TIMEOUT_MS))
          raise Rho::Error, "--timeout is milliseconds, and must be positive" unless timeout_ms.positive?

          cli = Rho::Dev.terminal(cli)
          relayed = cli.core.call_tool(runner, tool, input, timeout_ms: timeout_ms)
          row = relayed.fetch("task")
          cli.out.puts "run:         #{relayed.fetch("public_id")}"
          cli.print_task(row)
          print_content(cli, row)
          return row if row.fetch("status") == "completed"

          raise Rho::Error, "the request #{row.fetch("status")}: #{row.dig("error", "key") || "no result"}"
        end

        private

          def tool_input(input_json)
            return {} if input_json.nil? || input_json.to_s.strip.empty?

            input = JSON.parse(input_json)
            raise Rho::Error, "INPUT_JSON must be a JSON object" unless input.is_a?(Hash)

            input
          rescue JSON::ParserError => error
            raise Rho::Error, "INPUT_JSON is not JSON: #{error.message}"
          end

          # The result's blocks: text as itself, a link as its
          # line — the name, the type and size when named, the upload id
          # last so `rho fetch` takes it. A result with no blocks prints
          # its `output`, which is then the text alone or nothing.
          def print_content(cli, row)
            blocks = row["content"]
            return cli.out.puts(row["output"]) if blocks.nil? && row["output"]

            Array(blocks).each do |block|
              case block["type"]
              when "text" then cli.out.puts block["text"]
              when "resource_link" then cli.out.puts "link:      #{link_words(block)}"
              else next # a kind this rho does not know prints nothing; the kernel's read has it whole
              end
            end
          end

          def link_words(block)
            id = block["uri"].to_s.delete_prefix("nexus://uploads/")
            facts = [block["mimeType"], (block["size"] && "#{block["size"]} B")].compact
            [block["name"], (facts.any? ? "(#{facts.join(", ")})" : nil), id].compact.join(" ")
          end
      end
    end
  end
end
