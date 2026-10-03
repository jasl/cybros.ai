require "digest"
require "json"
require "zlib"
require_relative "../compose_bench/tools"
require_relative "job"

module E2E
  module Screen
    # Small synthetic cases for replay, counterfactual and door classification. Their identifiers
    # describe behavior, never a historical model run. Each script is evaluated under its declared
    # tool set; real run captures remain local artifacts outside this regression corpus.
    module Corpus
      DIR = File.expand_path("../fixtures/screen/corpus", __dir__)
      SCRIPTS = {
        "declared" => "declared_scripts.json",
        "bench" => "bench_scripts.jsonl.gz",
        "nul" => "nul_scripts.json",
      }.freeze
      FILES = SCRIPTS.merge("declarations" => "declarations.json", "door" => "door_records.jsonl").freeze

      Entry = Data.define(:id, :script, :params, :tool_names)
      # `tool_names` sorted; every entry's own names equal them. What the replay reads of a group
      # (`ReplayGate`): its `scripts`, each with its params, and the `declarations` its names stand
      # for (`Corpus.declarations`).
      Group = Data.define(:tool_names, :entries) do
        def scripts = entries.map { |entry| { "script" => entry.script, "params" => entry.params } }

        def declarations = Corpus.declarations(tool_names)
      end

      module_function

      def read(id)
        entries(id).group_by { |entry| entry.tool_names.sort }
          .map { |names, members| Group.new(tool_names: names, entries: members) }
      end

      def entries(id)
        rows(SCRIPTS.fetch(id)).map do |row|
          Entry.new(id: row.fetch("id"), script: row.fetch("script"), params: row.fetch("params"), tool_names: row.fetch("tool_names"))
        end
      end

      # A held declaration preserves its wire order; the bench's own tool sets use its definitions.
      def declarations(tool_names)
        held = declared_sets.find { |row| row.fetch("tool_names") == tool_names }
        held ? held.fetch("declarations") : bench_declarations(tool_names)
      end

      # One synthetic declaration per distinct tool set, in its original wire order.
      def declared_sets = rows(FILES.fetch("declarations"))

      # Synthetic rounds in record shape, each call carrying its name and input.
      def door_records = rows(FILES.fetch("door"))

      def sha256(id) = Digest::SHA256.file(path(id)).hexdigest

      def path(id) = File.join(DIR, FILES.fetch(id))

      # An unknown tool set is refused rather than silently borrowing another declaration.
      def bench_declarations(tool_names)
        foreign = tool_names - ComposeBench::Tools::NAMES
        raise Refused, "the corpus holds no declarations for #{foreign.join(", ")}" if foreign.any?

        ComposeBench::Tools.function_definitions.select { |entry| tool_names.include?(entry.dig("function", "name")) }
      end

      # Corpus files accept a JSON array, JSON lines, or gzipped JSON lines.
      def rows(name)
        file = File.join(DIR, name)
        if name.end_with?(".json")
          JSON.parse(File.read(file, encoding: "UTF-8"))
        elsif name.end_with?(".jsonl.gz")
          lines(Zlib::GzipReader.open(file, encoding: "UTF-8", &:read))
        else
          lines(File.read(file, encoding: "UTF-8"))
        end
      end

      def lines(text) = text.each_line.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }

      private_class_method :bench_declarations, :rows, :lines
    end
  end
end
