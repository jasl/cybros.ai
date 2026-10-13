require "test_helper"

# THE ONE MEASURE: the seal, the composer and the preview read one formula for a request's storage
# bytes — the canonical size of each entry, summed, against `snapshot_bound` — so a preview that
# says "within" is a seal that will not refuse, and a composition the wall refuses is one the
# preview would have shown over.
class ContentBodies::MeasureTest < ActiveSupport::TestCase
  ENTRIES = [
    { "role" => "user", "parts" => [{ "type" => "text", "text" => "one" }] },
    { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "two" }] },
  ].freeze

  test "the bytes are the canonical entries summed, against the snapshot bound" do
    measured = ContentBodies::Measure.call(ENTRIES)

    assert_equal ENTRIES.sum { |entry| Nexus::CanonicalJson.bytesize(entry) }, measured.bytes
    assert_equal Nexus::SizeBounds.fetch(:snapshot_bound), measured.bound
    assert_predicate measured, :within_bound?
    assert_nil measured.refusal
    assert_equal 0, ContentBodies::Measure.call([]).bytes
  end

  test "the seal's number is the measure's" do
    inference_request = InferenceRequest.create!(account: accounts(:cybros), workspace: workspaces(:shared),
      creating_user: users(:member), workload: "text_generation")
    result = ContentBodies::Replace.call(owner: inference_request, role: "input", entries: ENTRIES, seal: true)
    assert_predicate result, :accepted?

    sizes = ENTRIES.map { |entry| Nexus::ContentAddress.for(account_id: inference_request.account_id, payload: entry).byte_size }
    assert_equal ContentBodies::Measure.call(ENTRIES).bytes, sizes.sum, "the addressed bytes ARE the measure's"
    assert_equal sizes.sum + ENTRIES.length - 1, result.body.byte_size,
      "the stored byte_size is the effective text's — the same sum plus the newline joins — never a third formula"
  end

  test "over the bound in aggregate or in one entry is the bound's typed rejection, and the sum still answers" do
    bound = Nexus::SizeBounds.fetch(:snapshot_bound)
    huge = { "role" => "user", "parts" => [{ "type" => "text", "text" => "x" * bound }] }

    one = ContentBodies::Measure.call([huge])
    assert_not_predicate one, :within_bound?
    assert_equal Nexus::SizeBounds::REJECTION, one.refusal
    assert_operator one.bytes, :>, bound, "the number is still reported — a preview shows the overflow"

    half = { "role" => "user", "parts" => [{ "type" => "text", "text" => "x" * (bound / 2) }] }
    aggregate = ContentBodies::Measure.call([half, half, half])
    assert_predicate ContentBodies::Measure.call([half]), :within_bound?
    assert_not_predicate aggregate, :within_bound?, "three halves exceed the aggregate bound though each fits"
  end
end
