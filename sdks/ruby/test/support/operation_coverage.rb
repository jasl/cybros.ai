require "json"
require "set"

module CybrosAgentTest
  # Full-suite evidence is collected from real resource calls. Direct tests of
  # Dispatch cannot satisfy this gate because they have no SDK resource frame.
  module OperationCoverage
    ROOT = File.expand_path("../../../../contracts/nexus/v1", __dir__)
    OPERATIONS = JSON.parse(File.read(File.join(ROOT, "operations.json"))).fetch("operations")
      .select { |entry| entry.fetch("sdk_supported") }.freeze
    SEEN = Set.new
    MATCHERS = OPERATIONS.map do |entry|
      template = entry.fetch("path")
      expression = Regexp.escape(template).gsub(/\\\{[^}]+\\\}/, "[^/]+")
      [entry.fetch("method").downcase.to_sym, Regexp.new("\\A#{expression}\\z"), entry.fetch("id")]
    end.freeze

    def self.record(path, method, locations)
      resource = locations.any? do |location|
        location.path.include?("/lib/cybros_agent/") && !location.path.end_with?("/api/dispatch.rb")
      end
      return unless resource

      MATCHERS.each do |verb, matcher, id|
        SEEN << id if method == verb && matcher.match?(path)
      end
    end

    module Recording
      def call_accepting(path, method: :get, **options)
        OperationCoverage.record(path, method, caller_locations)
        super
      end

      def download(path, **options)
        OperationCoverage.record(path, :get, caller_locations)
        super
      end
    end

    def self.verify!
      missing = OPERATIONS.map { |entry| entry.fetch("id") }.to_set - SEEN
      raise "Ruby public-operation behavior coverage missing #{missing.size}:\n#{missing.to_a.sort.join("\n")}" unless missing.empty?

      puts "Ruby public-operation behavior coverage: #{SEEN.size}/#{OPERATIONS.size}"
    end
  end
end

CybrosAgent::Api.const_get(:Dispatch).prepend(CybrosAgentTest::OperationCoverage::Recording)
Minitest.after_run { CybrosAgentTest::OperationCoverage.verify! }
