require "test_helper"

class SpeakersTest < Minitest::Test
  def test_owner_and_external_conversations_share_the_same_speaker_binding
    own = Rho::Speakers.memory_context
    external = Rho::Speakers.memory_context(audience: "external")
    assert_equal %w[conversation speaker agent workspace], own.fetch("bindings").map { |row| row.fetch("name") }
    assert_equal %w[conversation speaker workspace], external.fetch("bindings").map { |row| row.fetch("name") }
    assert_equal own.fetch("bindings")[1], external.fetch("bindings")[1]
    assert_equal "read", external.fetch("bindings").last.fetch("access")
    assert_raises(ArgumentError) { Rho::Speakers.memory_context(audience: "unknown") }
  end
end
