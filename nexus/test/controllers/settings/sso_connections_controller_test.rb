require "test_helper"

class Settings::SsoConnectionsControllerTest < ActionDispatch::IntegrationTest
  test "the session survives enforcement and its only sign-in method cannot be removed" do
    user = users(:member)
    sign_in_as user
    provider = user.account.sso_providers.create!(name: "Staff", protocol: "oidc", issuer: "https://staff.example.test",
      client_id: "test-app", client_secret: "original-secret", enabled: true, tested_at: Time.current)
    connection = provider.sso_connections.create!(identity: user.identity, subject: "123")
    user.account.update!(sso_only: true)
    get settings_sso_connections_path
    assert_response :success
    assert_select "button[disabled]", text: "Disconnect"
    assert_select "form[action=?]", settings_sso_connection_path(provider), count: 0
    delete settings_sso_connection_path(provider), params: { current_password: "password" }
    assert_redirected_to settings_sso_connections_path
    assert connection.reload
    assert_match(/last sign-in method/, flash[:alert])
    get settings_path
    assert_response :success
    user.account.update!(sso_only: false)
    delete settings_sso_connection_path(provider), params: { current_password: "incorrect" }
    assert connection.reload
    delete settings_sso_connection_path(provider), params: { current_password: "password" }
    refute SsoConnection.exists?(connection.id)
    get settings_path
    assert_response :success
  end
  test "an SSO-only member can unlink one provider with proof from their other connected provider" do
    member = users(:member)
    sign_in_as member
    methods = %w[gitlab directory].map do |name|
      source = member.account.sso_providers.create!(name: name, protocol: "oidc", issuer: "https://#{name}.example.test",
        enabled: true, tested_at: Time.current)
      source.sso_connections.create!(identity: member.identity, subject: "99")
    end
    member.account.update!(sso_only: true)
    target = methods.first.sso_provider
    session = member.identity.sessions.sole
    make_proof = lambda do |source|
      source.sso_attempts.create!(purpose: "reauth", phase: "proved", session: session, subject: "99",
        state_digest: SecureRandom.hex(32), browser_digest: SecureRandom.hex(32), nonce: SecureRandom.hex(32),
        redirect_uri: "https://example.test/callback", provider_version: source.lock_version,
        action_name: "sso_disconnect", action_target: target.public_id, expires_at: 5.minutes.from_now)
    end
    make_proof.call(target)
    delete settings_sso_connection_path(target), params: { current_password: "password" }
    assert SsoConnection.exists?(methods.first.id)
    receipt = make_proof.call(methods.last.sso_provider)
    delete settings_sso_connection_path(target)
    assert_redirected_to settings_sso_connections_path
    refute SsoConnection.exists?(methods.first.id)
    refute SsoAttempt.exists?(receipt.id)
    assert SsoConnection.exists?(methods.last.id)
    get settings_sso_connections_path
    assert_response :success
    assert_select "button[disabled]", text: "Disconnect"
  end
end
