require "test_helper"

# The hidden test of the sample task (their form): run inside the
# container by `ruby -Itest /tests/verification_test.rb` after the graded
# surfaces are restored; its exit status is the verdict.
class SampleVerificationTest < ActionDispatch::IntegrationTest
  test "the eleventh search in a minute is refused" do
    10.times { get "/search", params: { q: "rails" } }
    assert_response :success
    get "/search", params: { q: "rails" }
    assert_response :too_many_requests
  end
end
