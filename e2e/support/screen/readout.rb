require "fileutils"
require "json"
require_relative "analysis"
require_relative "job"
require_relative "stamp"

module E2E
  module Screen
    # Readouts outlive a screen's ephemeral home as local artifacts. A reviewed
    # written conclusion can be saved separately; generated stamps and cells are
    # never regression fixtures or committed reports.
    #
    # IT IS THE SCREEN'S LEDGER: the launch read out last (`latest`). A screen is read out once, and
    # once more by its one relaunch, whose stamp names the stamp it supersedes: that readout moves the
    # earlier one aside into `superseded-<launched_at>/` rather than writing over it, and any other
    # is refused.
    module Readout
      FILES = %w[stamp.txt analysis.md counts.txt].freeze

      # The launch a screen's readout holds: its stamp, that stamp's sha, and its analysis's machine
      # lines (`verdict`, `relaunch`).
      Latest = Data.define(:stamp, :stamp_sha256, :machine)

      module_function

      def dir(root, definition) = File.join(root, "e2e", "artifacts", "screen-readouts", definition.name)

      def write(home:, definition:, root:, cells:)
        missing = FILES.reject { |name| File.exist?(File.join(home, name)) }
        raise Refused, "#{home} holds no #{missing.join(", ")}: nothing to read out" if missing.any?

        dest = dir(root, definition)
        FileUtils.mkdir_p(dest)
        set_aside(dest, Stamp.read(home))
        FILES.each { |name| FileUtils.cp(File.join(home, name), File.join(dest, name)) }
        File.write(File.join(dest, "cells.jsonl"), cells.map { |cell| "#{JSON.generate(cell)}\n" }.join)
        dest
      end

      # The launch the readout at `dest` holds, or nil when none was read out.
      def latest(dest)
        if File.exist?(Stamp.path(dest))
          Latest.new(stamp: Stamp.read(dest), stamp_sha256: Stamp.sha256(dest), machine: Analysis.machine_lines(File.join(dest, Analysis::FILE)))
        end
      end

      def set_aside(dest, stamp)
        return unless File.exist?(Stamp.path(dest))

        earlier = Stamp.read(dest)
        unless stamp["supersedes_stamp_sha256"] == Stamp.sha256(dest)
          raise Refused, "#{dest} reads out the launch of #{earlier["launched_at"]}, which this launch does not supersede: " \
                         "a screen is read out once, and once more by its one relaunch"
        end

        aside = File.join(dest, "superseded-#{Stamp.launched_at(earlier).utc.strftime("%Y%m%dT%H%M%SZ")}")
        FileUtils.mkdir_p(aside)
        [*FILES, "cells.jsonl"].each do |name|
          FileUtils.mv(File.join(dest, name), File.join(aside, name)) if File.exist?(File.join(dest, name))
        end
      end
      private_class_method :set_aside
    end
  end
end
