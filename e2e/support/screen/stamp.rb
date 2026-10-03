require "digest"
require "fileutils"
require "time"
require_relative "job"

module E2E
  module Screen
    # THE STAMP: one `key=value` line per registered fact, written ONCE by the launch before any
    # paid draw (after the smoke) into `<home>/stamp.txt`, and read by the watch and the analysis.
    # A second write over it is refused — a launch never re-stamps its home — and a failure between
    # the stamp and the first job voids it (`stamp.void-<ts>.txt`), since nothing it registered
    # was drawn. Keys are unique and values are one line each; the job table rides it as `job.<i>`
    # lines (`Job#stamp_line`).
    module Stamp
      FILE = "stamp.txt".freeze

      module_function

      def path(home) = File.join(home, FILE)

      def write(home, pairs)
        keys = pairs.map(&:first)
        repeated = keys.tally.select { |_key, count| count > 1 }.keys
        raise Refused, "the stamp names #{repeated.join(", ")} twice" if repeated.any?

        multiline = pairs.find { |key, value| key.to_s.match?(/[=\s]/) || value.to_s.include?("\n") }
        raise Refused, "the stamp's #{multiline.first.inspect} is not one key=value line" if multiline

        FileUtils.mkdir_p(home)
        File.write(path(home), pairs.map { |key, value| "#{key}=#{value}\n" }.join, encoding: Encoding::UTF_8, mode: "wx")
        path(home)
      rescue Errno::EEXIST
        raise Refused, "#{path(home)} exists: a home is stamped once"
      end

      def read(home)
        File.readlines(path(home), chomp: true, encoding: Encoding::UTF_8).to_h { |line| line.split("=", 2) }
      end

      def sha256(home) = Digest::SHA256.file(path(home)).hexdigest

      # The stamp moved aside as evidence; the slot freed for the relaunch it is not.
      def void(home, at: Time.now.utc)
        voided = File.join(home, "stamp.void-#{at.strftime("%Y%m%dT%H%M%SZ")}.txt")
        File.rename(path(home), voided)
        voided
      end

      def jobs(stamp)
        stamp.filter_map { |key, line| Job.from_stamp_line(key.delete_prefix("job."), line) if key.start_with?("job.") }
          .sort_by(&:index)
      end

      def launched_at(stamp) = Time.iso8601(stamp.fetch("launched_at"))
    end
  end
end
