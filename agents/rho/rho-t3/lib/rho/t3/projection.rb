module Rho
  module T3
    TERMINAL_STATUSES = %w[completed interrupted failed cancelled rolled_back].freeze
    Projection = Data.define(:raw) do
      def initialize(raw:)
        document = raw.to_h
        thread = document.fetch("thread").to_h
        %w[id projectId runtimeMode modelSelection branch worktreePath].each { |key| thread.fetch(key) }
        %w[runs subagents messages runtimeRequests turnItems nodes providerSessions].each do |key|
          document[key] = document.fetch(key).map(&:to_h)
        end
        document.fetch("runs").each { |run| %w[id ordinal status modelSelection].each { |key| run.fetch(key) } }
        document.fetch("messages").each { |message| %w[id role text].each { |key| message.fetch(key) } }
        document.fetch("subagents").each { |worker| worker.fetch("status") }
        document.fetch("runtimeRequests").each { |request| %w[id nodeId kind status responseCapability].each { |key| request.fetch(key) } }
        document.fetch("turnItems").each { |item| item.fetch("type") }
        super(raw: document)
      rescue KeyError, TypeError, NoMethodError
        raise Error, "T3 returned an incomplete thread projection", cause: nil
      end

      def thread = raw.fetch("thread")
      def runs = raw.fetch("runs")
      def run = runs.max_by { |item| item.fetch("ordinal") }
      def model_selection = (run || thread).fetch("modelSelection")
      def terminal? = run && TERMINAL_STATUSES.include?(run.fetch("status")) && active_workers.empty?
      def active_workers = raw.fetch("subagents").select { |item| %w[pending running waiting].include?(item.fetch("status")) }
      def messages = raw.fetch("messages")
      def requests = raw.fetch("runtimeRequests").select { |item| item.fetch("status") == "pending" }
      def items = raw.fetch("turnItems")
      def request_item(request) = items.find { |item| item["requestId"] == request.fetch("id") }

      def requested_action(request)
        node = raw.fetch("nodes").find { |item| item.fetch("id") == request.fetch("nodeId") }
        return nil unless node

        items.find do |item|
          next false if item["requestId"]

          item.fetch("nodeId") == node["parentNodeId"] ||
            (node.dig("nativeItemRef", "nativeId") && item["nativeItemRef"] == node["nativeItemRef"])
        end
      end

      def request_cwd(request)
        session_id = request.fetch("responseCapability")["providerSessionId"]
        raw.fetch("providerSessions").find { |session| session.fetch("id") == session_id }&.fetch("cwd")
      end

      def request_live?(request)
        capability = request.fetch("responseCapability")
        if capability.fetch("type") == "message"
          request.fetch("kind") == "user_input"
        elsif capability.fetch("type") == "live"
          raw.fetch("providerSessions").any? do |session|
            session.fetch("id") == capability.fetch("providerSessionId") && %w[ready running waiting].include?(session.fetch("status"))
          end
        else
          false
        end
      end

      def report
        { "status" => run&.fetch("status") || "not_started", "model" => model_selection.fetch("model"),
          "worktree" => thread["worktreePath"], "branch" => thread["branch"],
          "text" => messages.select { |item| item.fetch("role") == "assistant" }.map { |item| item.fetch("text") }.join("\n"),
          "checks" => items.select { |item| item.fetch("type") == "command_execution" }.map { |item| item.slice("input", "output", "exitCode", "outputIndicatesFailure", "outputOmitted") },
          "workers" => raw.fetch("subagents").map { |worker| worker.slice("title", "status", "model", "description") },
          "requests" => requests.map { |request| question_report(request) } }
      end

      private

      def question_report(request)
        item = request_item(request) || {}
        { "kind" => request.fetch("kind"), "prompt" => item["prompt"],
          "questions" => item.fetch("questions", []).map do |question|
            { "prompt" => question["question"] || question["header"],
              "options" => question.fetch("options", []).map { |option| option.fetch("label") } }.compact
          end }.compact
      end
    end
  end
end
