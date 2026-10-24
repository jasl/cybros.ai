require "fileutils"
require "json"
require "tmpdir"
require_relative "scorecard"

module E2E
  module Evals
    # The trace files and logs for one invocation. The ledger keeps its logical
    # cell keys; each record points at the trace stored here. Reserving a fresh
    # directory retains every earlier attempt, including its boot and runner logs.
    class Artifacts
      attr_reader :directory

      def initialize(root:, label:)
        parent = File.join(root, label)
        FileUtils.mkdir_p(parent)
        @directory = Dir.mktmpdir("invocation-", parent)
      end

      def stem(run) = File.join(directory, run.stem)

      def logs(*parts) = File.join(directory, "logs", *parts)

      def write(run, trace, record)
        path = stem(run)
        File.write("#{path}.json", JSON.pretty_generate({
          "record" => record, "graph" => trace.graph, "tasks" => trace.tasks, "events" => trace.events,
          "spend" => trace.spend, "facts" => trace.facts.except("summaries"), "summaries" => trace.fact("summaries"),
          "sealed_request" => trace.sealed,
        }))
        verdict_line = record.dig("verdict", "class").nil? ? "pass" : "#{record.dig("verdict", "class")}: #{Scorecard.reason_of(record)}"
        File.write("#{path}.md", "# #{run.task.name} on #{run.model} (#{run.style}) ##{run.index}\n\n" \
          "verdict: #{verdict_line}\n\n```mermaid\n#{trace.graph.fetch("mermaid")}\n```\n")
      end
    end
  end
end
