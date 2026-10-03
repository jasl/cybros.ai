$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "support/screen/definition"
require "support/screen/readout"
require "support/screen/stamp"

# THE READOUT IS WHAT OUTLIVES A SCREEN: the stamp, the analysis, the count and the cells (counts
# per arm × instrument × model × objective, no script bytes) copied out of the ephemeral home into
# the local `e2e/artifacts/screen-readouts/<screen>/`, separate from source. It is the screen's ledger:
# only the relaunch whose stamp names the one read out moves it aside, and any other readout is
# refused. Pure Ruby over tmpdirs.
class ScreenReadoutHarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  CELLS = [{ "arm" => "base", "instrument" => "compose", "model" => "m", "objective" => "O1", "draws" => 2, "right" => 1 }].freeze

  def test_the_four_files_land_in_the_screens_analysis_directory
    Dir.mktmpdir("screen-readout") do |root|
      home = finished_home(root, "2026-09-28T10:00:00Z")
      dest = S::Readout.write(home: home, definition: definition, root: root, cells: CELLS)
      assert_equal File.join(root, "e2e/artifacts/screen-readouts/fake-rehearsal"), dest
      assert_equal %w[analysis.md cells.jsonl counts.txt stamp.txt], Dir.children(dest).sort
      assert_equal File.read(S::Stamp.path(home)), File.read(File.join(dest, "stamp.txt"))
      assert_equal CELLS, File.readlines(File.join(dest, "cells.jsonl"), chomp: true).map { |line| JSON.parse(line) }
    end
  end

  def test_a_relaunchs_readout_moves_the_earlier_one_aside
    Dir.mktmpdir("screen-readout") do |root|
      first = finished_home(File.join(root, "first"), "2026-09-28T10:00:00Z")
      S::Readout.write(home: first, definition: definition, root: root, cells: CELLS)
      second = finished_home(File.join(root, "second"), "2026-09-28T11:30:00Z",
        supersedes: [["supersedes", "#{first} (STOPPED STORM)"], ["supersedes_stamp_sha256", S::Stamp.sha256(first)]])
      File.write(File.join(second, "analysis.md"), "the relaunch\n")
      dest = S::Readout.write(home: second, definition: definition, root: root, cells: CELLS)
      assert_equal "the relaunch\n", File.read(File.join(dest, "analysis.md"))
      aside = File.join(dest, "superseded-20260928T100000Z")
      assert_equal %w[analysis.md cells.jsonl counts.txt stamp.txt], Dir.children(aside).sort
      assert_equal "the verdict\n", File.read(File.join(aside, "analysis.md"))
    end
  end

  # A readout moves aside only for the relaunch that supersedes it: a second plain launch of the
  # screen, or a relaunch of another launch, is refused and the ledger stands.
  def test_a_readout_that_does_not_supersede_the_one_read_out_is_refused
    Dir.mktmpdir("screen-readout") do |root|
      first = finished_home(File.join(root, "first"), "2026-09-28T10:00:00Z")
      S::Readout.write(home: first, definition: definition, root: root, cells: CELLS)
      plain = finished_home(File.join(root, "plain"), "2026-09-28T11:30:00Z")
      other = finished_home(File.join(root, "other"), "2026-09-28T12:00:00Z",
        supersedes: [["supersedes", "/elsewhere (STOPPED STORM)"], ["supersedes_stamp_sha256", "0" * 64]])
      [plain, other].each do |home|
        error = assert_raises(S::Refused) { S::Readout.write(home: home, definition: definition, root: root, cells: CELLS) }
        assert_includes error.message, "does not supersede"
      end
      dest = File.join(root, "e2e/artifacts/screen-readouts/fake-rehearsal")
      assert_equal File.read(S::Stamp.path(first)), File.read(File.join(dest, "stamp.txt")), "the ledger stands"
      assert_empty Dir[File.join(dest, "superseded-*")]
    end
  end

  def test_a_home_without_its_analysis_is_refused
    Dir.mktmpdir("screen-readout") do |root|
      home = finished_home(root, "2026-09-28T10:00:00Z")
      File.delete(File.join(home, "analysis.md"))
      assert_raises(S::Refused) { S::Readout.write(home: home, definition: definition, root: root, cells: CELLS) }
    end
  end

  private

    def definition = S::Definition.load(FAKE)

    def finished_home(root, launched_at, supersedes: [])
      home = File.join(root, "home")
      S::Stamp.write(home, [%w[mode real], *supersedes, ["launched_at", launched_at]])
      File.write(File.join(home, "analysis.md"), "the verdict\n")
      File.write(File.join(home, "counts.txt"), "ok 1 base/compose/m: 2/2\n")
      home
    end
end
