require "test_helper"

class MemoryContextTest < ActiveSupport::TestCase
  test "speaker subjects are explicit and independent of private agent notes" do
    speaker = Speakers::Resolve.member(account: users(:member).account, user: users(:member))
    configuration = { "bindings" => [
      { "name" => "conversation", "scope" => "conversation", "access" => "read_write" },
      { "name" => "speaker", "scope" => "speaker", "access" => "read_write", "speaker_public_id" => speaker.public_id },
    ] }
    assert MemoryContext.from_h(configuration).valid?
    assert_equal %i[conversation workspace agent speaker], MemoryContext::DEFAULT.bindings.map(&:scope)
  end
end
