require "test_helper"

class SessionApiKindTest < ActiveSupport::TestCase
  setup do
    @identity = identities(:member)
  end

  test "bearer authentication resolves only usable api sessions" do
    issued = start_api_session

    assert_equal issued.session, Session.authenticate_api_token(issued.secret)
    assert_nil Session.authenticate_api_token(issued.secret.chop + "!")
    assert_nil Session.authenticate_api_token("sk-cybros-session-v1-nonsense")

    users(:member).suspend
    assert_nil Session.authenticate_api_token(issued.secret)
  end

  test "the two transports never cross kinds" do
    issued = start_api_session
    browser = create_browser_session(@identity)

    # An api session's public id in a cookie resumes nothing.
    assert_nil Session.find_usable(issued.session.public_id)
    assert_equal "API session", issued.session.device_description
    assert_equal browser, Session.find_usable(browser.public_id)

    # A browser session has no bearer wire at all.
    assert_nil browser.lookup_id
  end

  test "browser rows refuse bearer parts and api rows require them" do
    assert_raises ActiveRecord::RecordInvalid do
      @identity.sessions.create!(kind: :api)
    end

    browser = @identity.sessions.new(lookup_id: "x" * 24, secret_digest: "y")
    assert_not browser.valid?
  end

  private

    def start_api_session
      Sessions::Start.call(
        source: Sessions::Start::Credentials.new(email: @identity.email, password: "password"),
        kind: :api
      )
    end
end
