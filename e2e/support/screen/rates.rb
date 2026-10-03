require "digest"
require "fileutils"
require_relative "../bench_spend"
require_relative "job"

module E2E
  module Screen
    # THE RATES THE SPEND STOP PRICES BY, derived once per launch from the kernel's own pricing:
    # `BenchSpend.derive` runs the bench-spend runner under each tree's `bin/rails runner` and answers
    # the effective schedule of every model the launch draws — the cells' and the smoke's, since the
    # smoke's draws are priced into the spend too — refusing a lane settlement would write no money
    # for. The two trees must answer the same document — both arms are priced by one schedule — and
    # the answer is written to `<home>/rates.json` (`BenchSpend.write`), which the watch's pricer and
    # the analysis read (`BenchSpend.rates`), and hashed into the stamp. Nothing here restates a rate.
    module Rates
      # `derive` is `(root:, models:) → document`; a test passes its own.
      def self.call(definition:, trees:, home:, derive: BenchSpend.method(:derive))
        documents = trees.values.uniq.to_h do |root|
          [root, derive.call(root: root, models: definition.drawn_models)]
        rescue StandardError => error
          raise Refused, "the rates runner failed in #{root}: #{error.class}: #{error.message.lines.first(3).join.strip}"
        end
        raise Refused, "the two trees price the screen differently (#{documents.keys.join(" vs ")})" unless documents.values.uniq.size == 1

        FileUtils.mkdir_p(home)
        BenchSpend.write(home, documents.values.first)
        [["rates_sha256", Digest::SHA256.file(path(home)).hexdigest]]
      end

      def self.path(home) = File.join(home, BenchSpend::RATES_FILE)
    end
  end
end
