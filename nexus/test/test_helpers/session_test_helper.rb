module SessionFixtureTestHelper
  def create_browser_session(identity, user_agent: nil, ip_address: nil)
    Sessions::Start.call(source: identity, user_agent: user_agent, ip_address: ip_address).session
  end
end

module SessionTestHelper
  # Sign in through the real flow (POST /session), never by minting a Session row directly. Fixture
  # identities share the password "password".
  def sign_in_as(user, password: "password")
    post session_url, params: { email: user.email, password: password }
    assert cookies[:session_id].present?, "expected sign-in to set the session cookie"
  end

  def sign_out
    delete session_url
    assert cookies[:session_id].blank?, "expected sign-out to clear the session cookie"
  end
end

ActiveSupport.on_load(:action_dispatch_integration_test) do
  include SessionTestHelper
end
