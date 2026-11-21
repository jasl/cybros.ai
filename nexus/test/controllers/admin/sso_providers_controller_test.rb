require "test_helper"

class Admin::SsoProvidersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    sign_in_as users(:owner)
  end

  test "an administrator configures a draft and receives a callback without exposing its secret" do
    get new_admin_sso_provider_path
    assert_response :success
    post admin_sso_providers_path, params: { sso_provider: {
      name: "Company GitLab", protocol: "oidc", issuer: "https://gitlab.example.test",
      client_id: "gitlab-app", client_secret: "test-credential",
    } }
    provider = @account.sso_providers.sole
    assert_redirected_to admin_sso_provider_path(provider)
    refute provider.enabled?
    refute_includes provider.client_secret_before_type_cast, "test-credential"
    follow_redirect!
    assert_select "dd", text: /sso\/providers\/#{provider.public_id}\/callback/
    assert_select "form[action=?]", sso_start_path(provider)
    get edit_admin_sso_provider_path(provider)
    assert_select "input[name='sso_provider[client_secret]'][value]", count: 0
    refute_includes response.body, "test-credential"

    post admin_sso_provider_activation_path(provider), params: { lock_version: provider.lock_version }
    refute provider.reload.enabled?
    assert provider.accept_test(expected_version: provider.lock_version)
    post admin_sso_provider_activation_path(provider), params: { lock_version: provider.lock_version }
    assert provider.reload.enabled?
    sign_out
    get new_session_path
    assert_select "form[action=?]", sso_start_path(provider)
  end

  test "a candidate credential becomes live only after that exact configuration passes its test" do
    provider = enabled_provider
    version = provider.lock_version
    patch admin_sso_provider_path(provider), params: { sso_provider: { client_secret: "replacement-secret", lock_version: version } }
    assert_redirected_to admin_sso_provider_path(provider)
    assert_equal "original-secret", provider.reload.client_secret
    assert_equal "replacement-secret", provider.test_candidate.client_secret
    refute_includes provider.pending_configuration_before_type_cast, "replacement-secret"
    refute provider.accept_test(expected_version: version)
    assert_equal "original-secret", provider.reload.client_secret
    assert provider.accept_test(expected_version: provider.lock_version)
    assert_equal "replacement-secret", provider.reload.client_secret
    assert_nil provider.pending_configuration
  end

  test "requiring SSO is blocked until every active human is covered and no source can then be deleted" do
    provider = enabled_provider
    other = @account.sso_providers.create!(name: "Another company", protocol: "oidc", issuer: "https://other.example.test")
    patch admin_sso_policy_path, params: { mode: "sso_only", current_password: "password" }
    refute @account.reload.sso_only?
    get admin_sso_providers_path
    assert_response :success
    assert_select "input[type=submit][disabled]"
    @account.users.active.where(kind: :human).each { |user| connect(user.identity, provider) }
    patch admin_sso_policy_path, params: { mode: "sso_only", current_password: "password" }
    assert @account.reload.sso_only?
    delete admin_sso_provider_path(other), params: { lock_version: other.lock_version }
    assert other.reload
    delete admin_sso_provider_activation_path(provider), params: { lock_version: provider.lock_version }
    assert provider.reload.enabled?
    get admin_sso_provider_path(other)
    assert_response :success
    assert_select "form[action=?]", admin_sso_provider_path(other), count: 0
    get admin_sso_providers_path
    assert_response :success
  end

  test "mixed mode protects SSO-only people and permits explicit retirement after they acquire another method" do
    provider = enabled_provider
    identity = users(:member).identity
    connection = connect(identity, provider)
    identity.update_column(:password_digest, nil)
    delete admin_sso_provider_activation_path(provider), params: { lock_version: provider.lock_version }
    assert provider.reload.enabled?
    get admin_sso_provider_path(provider)
    assert_select "li", text: /Member.*member@example/
    identity.update_column(:password_digest, users(:owner).identity.password_digest)
    delete admin_sso_provider_activation_path(provider), params: { lock_version: provider.lock_version }
    refute provider.reload.enabled?
    assert connection.reload
    delete admin_sso_provider_path(provider), params: { lock_version: provider.lock_version, confirmation: "wrong" }
    assert connection.reload
    delete admin_sso_provider_path(provider), params: { lock_version: provider.lock_version, confirmation: provider.name }
    assert_redirected_to admin_sso_providers_path
    refute SsoConnection.exists?(connection.id)
    assert identity.reload
  end

  test "unused drafts can be corrected under SSO enforcement while published authority stays fixed" do
    provider = @account.sso_providers.create!(name: "Company SSO", protocol: "oidc", issuer: "https://mistype.example.test")
    @account.update!(sso_only: true)
    get edit_admin_sso_provider_path(provider)
    assert_select "input[name='sso_provider[issuer]']"
    patch admin_sso_provider_path(provider), params: { sso_provider: { lock_version: provider.lock_version,
      issuer: "https://correct.example.test", client_id: "application", client_secret: "test-secret" } }
    assert_equal "https://correct.example.test", provider.reload.issuer
    assert provider.accept_test(expected_version: provider.lock_version)
    assert provider.set_enabled(true, expected_version: provider.lock_version)
    @account.update!(sso_only: false)
    assert provider.set_enabled(false, expected_version: provider.lock_version)
    get edit_admin_sso_provider_path(provider)
    assert_select "input[name='sso_provider[issuer]']", count: 0
    patch admin_sso_provider_path(provider), params: { sso_provider: { lock_version: provider.lock_version,
      issuer: "https://replacement.example.test" } }
    assert_response :unprocessable_entity
    assert_equal "https://correct.example.test", provider.reload.issuer
  end

  test "deletion previews identify dormant people needing re-enrollment and preserve them" do
    provider = enabled_provider
    member = users(:member)
    connect(member.identity, provider)
    member.identity.update_column(:password_digest, nil)
    assert_equal :suspended, member.suspend
    assert provider.set_enabled(false, expected_version: provider.lock_version)
    get admin_sso_provider_deletion_path(provider)
    assert_response :success
    assert_select "li", text: /Member.*member@example/
    assert_select "form[action=?]", admin_sso_provider_path(provider)
    delete admin_sso_provider_path(provider), params: { confirmation: provider.name, lock_version: provider.lock_version }
    assert_redirected_to admin_sso_providers_path
    assert member.reload.suspended?
    assert member.identity.reload
  end

  test "loosening a login policy displays the number of active members with a password" do
    @account.update!(sso_only: true)
    users(:member).identity.update_column(:password_digest, nil)
    get admin_sso_providers_path
    assert_response :success
    assert_select "p", text: "Allowing passwords will restore password sign-in for 2 active members."
  end

  test "a member cannot administer providers" do
    sign_out
    sign_in_as users(:member)
    get admin_sso_providers_path
    assert_response :forbidden
  end

  private

    def enabled_provider
      @account.sso_providers.create!(name: "Company", protocol: "oidc", issuer: "https://gitlab.example.test",
        client_id: "test-app", client_secret: "original-secret", enabled: true, tested_at: Time.current)
    end

    def connect(identity, provider)
      provider.sso_connections.create!(identity: identity, subject: identity.user.public_id)
    end
end
