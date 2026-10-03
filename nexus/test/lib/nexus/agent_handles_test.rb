require "test_helper"

# THE NAME TABLE: the words the kernel assigns agent members as handles when a creation names none —
# short, neutral, every one a valid handle on its own, no repeats. Shipped with the kernel as code,
# read once.
class Nexus::AgentHandlesTest < ActiveSupport::TestCase
  test "the table holds a few hundred distinct words, each a valid handle" do
    words = Nexus::AgentHandles::WORDS

    assert_predicate words, :frozen?
    assert_operator words.length, :>=, 200
    assert_equal words.length, words.uniq.length, "no repeats"
    words.each do |word|
      assert_match User::Handle::FORMAT, word
      assert_operator word.length, :<=, 12, "short words leave room for a suffix"
    end
  end

  test "pick draws one word from the table" do
    assert_includes Nexus::AgentHandles::WORDS, Nexus::AgentHandles.pick
  end
end
