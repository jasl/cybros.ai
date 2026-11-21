require "test_helper"
require_relative "../../support/mcp_test_server"

class EnterpriseSignInTest < ActionDispatch::IntegrationTest
  setup do
    @account = accounts(:cybros)
    @subject = "worker-42"
    @email = "worker@example.org"
    @verified = true
    @wire = {}
    @server = McpTestServer.new { |request| provider_response(request) }
    @issuer = URI(@server.endpoint_url).origin
    @provider = @account.sso_providers.create!(name: "Enterprise", protocol: "oauth2", issuer: @issuer,
      client_id: "nexus", client_secret: "configured-secret", enabled: true, jit: true, scopes: "profile",
      authorization_endpoint: "#{@issuer}/authorize", token_endpoint: "#{@issuer}/token", userinfo_endpoint: "#{@issuer}/user")
  end
  teardown { @server.close }

  test "OAuth2 registration and subsequent login keep the same human across email changes" do
    start_flow
    assert_equal "S256", @outbound.fetch("code_challenge_method")
    assert_no_difference -> { Identity.count } do
      callback
    end
    assert_match "/confirmation", response.location
    follow_redirect!
    assert_select "input[name=display_name]"
    assert_difference [-> { Identity.count }, -> { User.count }, -> { SsoConnection.count }], 1 do
      post sso_confirmation_path(SsoAttempt.last.public_id), params: { display_name: "Enterprise Worker" }
    end
    assert_redirected_to root_path
    identity = Identity.find_by!(email: @email)
    assert_predicate identity.user, :member?
    assert_nil identity.reload.password_digest
    assert_not identity.authenticate("password")
    assert_no_difference -> { identity.sessions.count } do
      post api_v1_session_path, params: { email: identity.email, password: "password" }, as: :json
      assert_response :unauthorized
    end
    assert identity.user.memory_collections.exists?
    assert_equal identity, SsoConnection.sole.identity
    assert_equal identity, Session.last.identity

    sign_out
    @email = "new@example.org"
    start_flow
    callback
    assert_redirected_to root_path
    assert_equal identity, Session.last.identity
    assert_equal "worker@example.org", identity.reload.email
    assert_equal 1, SsoConnection.count
  end

  test "verified email collisions and invite-only addresses never attach an existing identity" do
    @email = identities(:owner).email
    start_flow
    assert_no_difference [-> { SsoConnection.count }, -> { Session.count }] do
      callback
    end
    assert_equal I18n.t("sso.existing_identity"), flash[:alert]

    @email = "reserved@example.org"
    @account.invitations.create!(email: @email, inviter: users(:owner))
    start_flow
    callback
    assert_equal I18n.t("sso.invitation_required"), flash[:alert]
    assert_nil Identity.find_by(email: @email)
  end

  test "explicitly connect one identity and reject a later cross-account binding" do
    sign_in_as users(:owner)
    owner_session = Session.last
    start_flow("connect", current_password: "password", return_to: settings_path)
    callback
    assert_match "/confirmation", response.location
    post sso_confirmation_path(SsoAttempt.last.public_id)
    assert_equal identities(:owner), SsoConnection.sole.identity
    assert_equal owner_session, Session.last

    sign_out
    sign_in_as users(:member)
    member_session = Session.last
    start_flow("connect", current_password: "password")
    assert_no_difference [-> { SsoConnection.count }, -> { Session.count }] do
      callback
    end
    assert_equal I18n.t("sso.subject_in_use"), flash[:alert]
    assert_equal identities(:owner), SsoConnection.sole.identity
    assert_equal member_session, Session.last
  end

  test "a valid invitation can bind a hidden upstream email, but an occupied subject cannot spend it" do
    @email = nil
    @verified = false
    invite = @account.invitations.create!(email: "invited@example.org", role: "admin", inviter: users(:owner))
    start_flow("invitation", invitation_token: invite.acceptance_token)
    callback
    assert_difference -> { Invitation.count }, -1 do
      post sso_confirmation_path(SsoAttempt.last.public_id), params: { display_name: "Invited Admin" }
    end
    assert_equal invite.email, SsoConnection.sole.identity.email
    assert_predicate Session.last.user, :admin?
    sign_out

    other = @account.invitations.create!(email: "other@example.org", inviter: users(:owner))
    start_flow("invitation", invitation_token: other.acceptance_token)
    assert_no_difference [-> { Invitation.count }, -> { Session.count }] do
      callback
    end
    assert_equal I18n.t("sso.invalid_invitation"), flash[:alert]
  end

  test "OIDC verifies the signed ID token before accepting an admitted GitLab-style subject" do
    configure_oidc
    @provider.sso_connections.create!(subject: @subject, identity: identities(:member))
    start_flow
    @nonce = @outbound.fetch("nonce")
    callback
    assert_redirected_to root_path
    assert_equal identities(:member), Session.last.identity
    sign_out

    start_flow
    @nonce = "different-request"
    assert_no_difference -> { Session.count } do
      callback
    end
    assert_equal I18n.t("sso.provider_error"), flash[:alert]
  end

  test "OIDC rejects wrong signing authority, audience, UserInfo identity and group before issuing any session" do
    configure_oidc
    member = users(:member)
    @provider.sso_connections.create!(identity: member.identity, subject: @subject)
    different_key = OpenSSL::PKey::RSA.generate(2048)
    cases = {
      "signature" => [{ signing_key: different_key }, :provider_error],
      "issuer" => [{ claims: { iss: "https://other.example.org" } }, :provider_error],
      "audience" => [{ claims: { aud: "other-client" } }, :provider_error],
      "authorized party" => [{ claims: { aud: ["nexus", "other"], azp: "other" } }, :provider_error],
      "UserInfo subject" => [{ info_subject: "other-subject" }, :provider_error],
      "required group" => [{ groups: ["other-org"] }, :admission_denied],
    }

    cases.each do |condition, (wire, reason)|
      @wire = wire
      start_flow
      @nonce = @outbound.fetch("nonce")
      assert_no_difference -> { Session.count }, condition do
        callback
      end
      assert_equal I18n.t("sso.#{reason}"), flash[:alert], condition
      assert_nil cookies[:session_id], condition
    end

    sign_in_as member
    args = { action_name: "settings_email", target: member.public_id, return_to: settings_email_path }
    proof_args = { session: Session.last, action: "settings_email", target: member.public_id }
    [nil, 6.minutes.ago.to_i].each do |auth_time|
      @wire = { claims: { auth_time: auth_time }.compact }
      start_flow("reauth", **args)
      @nonce = @outbound.fetch("nonce")
      assert_equal "300", @outbound.fetch("max_age")
      callback
      assert_equal I18n.t("sso.provider_error"), flash[:alert]
      assert_not Sso::Proof.valid?(**proof_args)
    end

    @wire = { claims: { auth_time: Time.current.to_i } }
    start_flow("reauth", **args)
    @nonce = @outbound.fetch("nonce")
    callback
    assert Sso::Proof.valid?(**proof_args)
  end

  test "replaying a callback or switching browser does not redeem another code" do
    start_flow
    isolated = open_session
    isolated.get sso_callback_path(@provider.public_id), params: { state: @outbound.fetch("state"), code: "one" }
    assert_empty @server.requests
    callback
    assert_equal 2, @server.requests.length
    callback
    assert_equal 2, @server.requests.length
    assert_equal "confirming", SsoAttempt.last.phase
  end

  test "a proof uses an existing bound subject, belongs to one operation, and can be consumed once" do
    sign_in_as users(:owner)
    @provider.sso_connections.create!(subject: @subject, identity: identities(:owner))
    start_flow("reauth", action_name: "settings_email", target: users(:owner).public_id, return_to: settings_email_path)
    callback
    assert_redirected_to settings_email_path
    args = { session: Session.last, action: "settings_email", target: users(:owner).public_id }
    assert_not Sso::Proof.consume(**args.merge(action: "settings_token"))
    assert_not Sso::Proof.consume(**args, excluding_provider: @provider)
    patch settings_email_path, params: { email: { email: "updated@example.org" } }
    assert_redirected_to settings_email_path
    assert_equal "updated@example.org", identities(:owner).reload.email
    patch settings_email_path, params: { email: { email: "replay@example.org" } }
    assert_response :unprocessable_entity
    assert_equal "updated@example.org", identities(:owner).reload.email

    start_flow("reauth", action_name: "settings_token", target: users(:owner).public_id)
    callback
    patch settings_email_path, params: { email: { email: "different-action@example.org" } }
    assert_response :unprocessable_entity
    assert_equal "updated@example.org", identities(:owner).reload.email
  end

  test "withdrawing an invitation or disabling the source between screens restores no rights" do
    invitation = @account.invitations.create!(email: @email, inviter: users(:owner))
    start_flow("invitation", invitation_token: invitation.acceptance_token)
    callback
    pending = SsoAttempt.last.public_id
    invitation.destroy!
    assert_no_difference [-> { Identity.count }, -> { SsoConnection.count }, -> { Session.count }] do
      post sso_confirmation_path(pending), params: { display_name: "Invited" }
    end
    assert_equal I18n.t("sso.invalid_invitation"), flash[:alert]

    start_flow
    @provider.update!(enabled: false)
    @provider.update!(enabled: true)
    assert_no_difference -> { Session.count } do
      callback
    end
    assert_equal I18n.t("sso.invalid"), flash[:alert]
  end

  test "a local recovery requires its own capability and changes only the named member's connection" do
    member = users(:member)
    original = @provider.sso_connections.create!(identity: member.identity, subject: @subject)
    recovery = MemberRecoveryAuthorizations::Issue.call(user: member, purpose: :sso_connection, lost_sso_provider: @provider)
    get sso_recovery_path(token: recovery.secret)
    assert_response :success
    assert_select "form"
    start_flow
    callback
    assert_nil cookies[:session_id]
    assert_equal I18n.t("sso.unavailable"), flash[:alert]

    @subject = "replacement"
    start_flow("recovery", recovery_token: recovery.secret)
    callback
    assert_match "/confirmation", response.location
    post sso_confirmation_path(SsoAttempt.last.public_id)
    assert_redirected_to new_session_path
    assert_equal @subject, member.identity.sso_connections.sole.subject
    assert_not SsoConnection.exists?(original.id)
    assert_predicate recovery.authorization.reload.consumed_at, :present?
    assert_not member.identity.reload.local_recovery_pending?
    assert member.identity.authenticate("password"), "a member-chosen password survives SSO connection recovery"
    get sso_recovery_path(token: recovery.secret)
    assert_response :not_found
    start_flow
    callback
    assert_equal member, Session.last.user
  end

  test "reconnecting a dormant temporary-password member retires the admin-issued password before mixed login resumes" do
    member = users(:member)
    member.identity.update!(password_change_required: true)
    assert_equal :suspended, member.suspend
    @account.update!(sso_only: true)
    assert_equal :restored_for_recovery, member.reactivate(reconnect: true)
    authorization = MemberRecoveryAuthorizations::Issue.call(user: member, purpose: :sso_connection)

    start_flow("recovery", recovery_token: authorization.secret)
    callback
    assert_match "/confirmation", response.location
    post sso_confirmation_path(SsoAttempt.last.public_id)
    assert_redirected_to new_session_path
    assert_nil member.identity.reload.password_digest
    assert_not member.identity.password_change_required?
    assert_not member.identity.local_recovery_pending?
    start_flow
    callback
    assert_redirected_to root_path
    assert_equal member, Session.last.user

    sign_out
    @account.update!(sso_only: false)
    assert_no_difference -> { Session.count } do
      post session_path, params: { email: member.identity.email, password: "password" }
    end
    assert_equal I18n.t("sessions.create.invalid_credentials"), flash[:alert]
  end

  test "a disabled draft can be tested without binding, signing in or exposing a credential" do
    @provider.update!(enabled: false)
    sign_in_as users(:owner)
    start_flow("test", return_to: admin_sso_provider_path(@provider))
    assert_no_difference [-> { Session.count }, -> { Identity.count }, -> { SsoConnection.count }] do
      callback
    end
    assert_redirected_to admin_sso_provider_path(@provider)
    assert_predicate @provider.reload.tested_at, :present?
    assert_not @provider.enabled?
    assert_not_includes flash[:notice], @subject
  end

  test "changing the browser session, suspending a member or requiring a new password rejects sign-in" do
    member = users(:member)
    @provider.sso_connections.create!(identity: member.identity, subject: @subject)
    start_flow
    sign_in_as users(:owner)
    callback
    assert_equal I18n.t("sso.invalid"), flash[:alert]
    assert_equal users(:owner), Session.last.user
    sign_out
    member.identity.update!(password_change_required: true)
    start_flow
    callback
    assert_equal I18n.t("sso.unavailable"), flash[:alert]
    member.identity.update!(password_change_required: false)
    start_flow
    member.suspend
    assert_no_difference -> { Session.count } do
      callback
    end
    assert_equal I18n.t("sso.unavailable"), flash[:alert]
    assert_equal member.identity, SsoConnection.sole.identity
  end

  private

    def configure_oidc
      @provider.destroy!
      @key = JWT::JWK.new(OpenSSL::PKey::RSA.generate(2048), kid: "oidc-test-key")
      @provider = @account.sso_providers.create!(protocol: "oidc", issuer: @issuer, name: "GitLab",
        client_id: "nexus", client_secret: "configured-secret", required_group: "corp", enabled: true)
    end

    def start_flow(purpose = "login", **options)
      post sso_start_path(@provider.public_id), params: { purpose: purpose, **options }
      assert_response :redirect
      destination = URI(response.location)
      assert_equal "/authorize", destination.path, flash[:alert]
      @outbound = URI.decode_www_form(destination.query).to_h
    end

    def callback
      get sso_callback_path(@provider.public_id), params: { code: "single-use-code", state: @outbound.fetch("state") }
    end

    # The peer verifies the actual form and returns independent JSON over HTTP.
    def provider_response(request)
      path = request.fetch(:line).split.fetch(1)
      case path
      when "/.well-known/openid-configuration"
        { json: { issuer: @issuer, authorization_endpoint: "#{@issuer}/authorize",
          token_endpoint: "#{@issuer}/token", userinfo_endpoint: "#{@issuer}/user", jwks_uri: "#{@issuer}/keys" } }
      when "/keys"
        { json: { keys: [@key.export] } }
      when "/token"
        form = URI.decode_www_form(request.fetch(:body)).to_h
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(form.fetch("code_verifier")), padding: false)
        return { status: 400 } unless challenge == @outbound.fetch("code_challenge") && form.fetch("redirect_uri") == @outbound.fetch("redirect_uri")
        result = { access_token: "test-token", token_type: "Bearer" }
        if @key
          claims = { iss: @issuer, sub: @subject, aud: "nexus", iat: Time.now.to_i, exp: 3.minutes.from_now.to_i, nonce: @nonce }
          claims.merge!(@wire.fetch(:claims, {}))
          result[:id_token] = JWT.encode(claims, @wire.fetch(:signing_key, @key.signing_key), "RS256", kid: @key.kid)
        end
        { json: result }
      when "/user"
        return { status: 401 } unless request.fetch(:headers)["authorization"] == "Bearer test-token"
        { json: { id: @subject, sub: @wire.fetch(:info_subject, @subject), email: @email, email_verified: @verified,
          name: "Developer", groups: @wire.fetch(:groups, ["corp"]) } }
      else
        { status: 404 }
      end
    end
end
