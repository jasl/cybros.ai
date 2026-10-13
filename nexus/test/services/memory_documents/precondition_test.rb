require "test_helper"

class MemoryDocuments::PreconditionTest < ActiveSupport::TestCase
  test "absence is explicit and only accepted for a write" do
    fields = { "expected_public_id" => nil, "expected_lock_version" => nil }
    assert MemoryDocuments::Precondition.parse(fields, allow_absent: true).matches?(nil)
    assert_raises(ArgumentError) { MemoryDocuments::Precondition.parse(fields, allow_absent: false) }
    assert_raises(KeyError) { MemoryDocuments::Precondition.parse({}, allow_absent: true) }
  end

  test "identity and version must both match the selected row" do
    document = MemoryDocument.new(public_id: SecureRandom.uuid_v7, lock_version: 2)
    fields = { "expected_public_id" => document.public_id.upcase, "expected_lock_version" => "2" }
    condition = MemoryDocuments::Precondition.parse(fields, allow_absent: false)
    assert condition.matches?(document)
    assert_not condition.matches?(nil)
    assert_not condition.matches?(MemoryDocument.new(public_id: document.public_id, lock_version: 3))
    assert_not condition.matches?(MemoryDocument.new(public_id: SecureRandom.uuid_v7, lock_version: 2))
  end
end
