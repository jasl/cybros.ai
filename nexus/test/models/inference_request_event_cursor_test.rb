require "test_helper"

# The sole allocator: contiguous ranges under the row lock and a positive
# count.
class InferenceRequestEventCursorTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @inference_request = InferenceRequest.create!(
      account: @account, workspace: workspaces(:shared), creating_user: users(:member),
      workload: "text_generation"
    )
    @cursor = InferenceRequestEventCursor.create!(account: @account, inference_request: @inference_request)
  end

  test "allocation is contiguous and advances by exactly the count" do
    assert_equal (1...4), @cursor.allocate_sequences(3)
    assert_equal (4...6), @cursor.allocate_sequences(2)
    assert_equal 6, @cursor.reload.next_sequence
  end

  test "a non-positive count refuses" do
    assert_raises(ArgumentError) { @cursor.allocate_sequences(0) }
  end
end
