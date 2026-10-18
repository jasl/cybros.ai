require "test_helper"
require "support/exit_long_pump"

# THE LONG LANE'S PUMP DECIDES ON PAPER BEFORE A PAID RUN. The scripted
# human of `live_exit_long` denies a `bash` / `start_process` park whose
# command reads the vector corpus with a shell verb (the index line needs
# the whole file through the read tool; a `head`/`tail` loop hands over
# all 56 in one park and the wall is never crossed) and approves every
# other park. The predicate is verb-anchored so the suite command, the
# server, an append to VECTORS.md and a listing pass — a pump that denied
# the port's own test run would end the lane at its own hand. Each row of
# the table is one command a model actually asked for, or could.
class ExitLongPumpHarnessTest < Minitest::Test
  P = E2E::ExitLongPump

  DENIED = [
    %(for f in spec/vectors/vec-*.txt; do first=$(head -1 "$f"); last=$(tail -1 "$f"); echo "$f: $first | $last"; done),
    "head -n 1 spec/vectors/vec-03.txt",
    "cat spec/vectors/vec-01.txt",
    "grep -n marker- spec/vectors/vec-*.txt",
    "sed -n 2p spec/vectors/vec-07.txt",
    "tail -n 1 spec/vectors/vec-56.txt",
    "awk 'NR==1' spec/vectors/vec-12.txt",
    "wc -l spec/vectors/vec-01.txt",
    "find spec/vectors -name 'vec-*.txt' -exec head -1 {} \\;",
    %(for i in $(seq -w 15 56); do f="spec/vectors/vec-$i.txt"; head -1 "$f"; done),
    "cd spec/vectors && cat vec-09.txt",
    "ls -la && cat spec/vectors/vec-02.txt",
  ].freeze

  APPROVED = [
    "ruby -Ilib -Itest test/all.rb",
    "ruby server/app.rb 43121",
    %(printf 'vec-01.txt: vector-abc of vec-01.txt | marker-def of vec-01.txt\\n' >> VECTORS.md),
    "ls spec",
    "ls spec/vectors",
    "cat PORT.md",
    "head -n 40 src/frame_codec.js",
    "grep -n SPEC_TOKEN lib/frame_codec.rb test/spec_token_test.rb",
    "sh check.sh",
    "mkdir -p lib && touch lib/frame_codec.rb",
    "wc -l VECTORS.md",
  ].freeze

  def test_the_reason_names_the_read_tool_and_one_file_per_call
    assert_equal "read the vector files with the read tool, one file per call", P::REASON
    assert_predicate P::REASON, :frozen?
  end

  def test_every_shell_read_of_the_corpus_is_denied_under_bash_and_start_process
    DENIED.each do |command|
      %w[bash start_process].each do |tool|
        assert P.bypass?(tool, { "command" => command }), "#{tool} #{command.inspect} should be denied"
      end
    end
  end

  def test_the_suite_the_server_an_append_and_a_listing_are_approved
    APPROVED.each do |command|
      %w[bash start_process].each do |tool|
        refute P.bypass?(tool, { "command" => command }), "#{tool} #{command.inspect} should be approved"
      end
    end
  end

  def test_a_read_ls_or_grep_tool_call_is_never_a_bypass_whatever_its_argument
    refute P.bypass?("read", { "path" => "spec/vectors/vec-01.txt" })
    refute P.bypass?("ls", { "path" => "spec/vectors" })
    refute P.bypass?("grep", { "pattern" => "marker-", "path" => "spec/vectors" })
    refute P.bypass?("write", { "path" => "VECTORS.md", "content" => "head spec/vectors/vec-01.txt" })
    refute P.bypass?("edit", { "path" => "VECTORS.md", "old_string" => "cat spec/vectors/vec-01.txt", "new_string" => "" })
  end

  def test_a_missing_or_non_string_command_is_not_a_bypass
    refute P.bypass?("bash", {})
    refute P.bypass?("bash", { "command" => nil })
    refute P.bypass?("bash", { "command" => 42 })
    refute P.bypass?("bash", nil)
  end

  def test_a_verb_on_one_line_never_reaches_a_vector_named_on_the_next
    refute P.bypass?("bash", { "command" => "ruby -Ilib -Itest test/all.rb\necho spec/vectors done" })
    assert P.bypass?("bash", { "command" => "ruby -Ilib -Itest test/all.rb\nhead -1 spec/vectors/vec-01.txt" })
  end
end
