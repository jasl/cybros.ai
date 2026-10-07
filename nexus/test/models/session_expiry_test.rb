require "test_helper"

class SessionExpiryTest < ActiveSupport::TestCase
  setup do
    freeze_time
    @identity = identities(:member)
    @browser = create_browser_session(@identity)
    @api = Sessions::Start.call(
      source: Sessions::Start::Credentials.new(email: @identity.email, password: "password"),
      kind: :api
    )
  end

  test "browser and API authentication stop at the absolute expiry" do
    travel_to @browser.expires_at - 1.second, with_usec: true

    assert_equal @browser, Session.find_usable(@browser.public_id)
    assert_equal @api.session, Session.authenticate_api_token(@api.secret)

    travel_to @browser.expires_at, with_usec: true

    assert_nil Session.find_usable(@browser.public_id)
    assert_nil Session.authenticate_api_token(@api.secret)
  end

  test "the active session list excludes rows at their absolute expiry" do
    travel_to @browser.expires_at - 1.second, with_usec: true

    assert_equal [@api.session, @browser], Session.listable_for(@identity).to_a

    travel_to @browser.expires_at, with_usec: true
    replacement = create_browser_session(@identity)

    assert_equal [replacement], Session.listable_for(@identity).to_a
  end
end
