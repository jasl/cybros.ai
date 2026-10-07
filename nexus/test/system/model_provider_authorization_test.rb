require "application_system_test_case"
require_relative "../test_helpers/model_provider_settings_journey"

class ModelProviderAuthorizationTest < ApplicationSystemTestCase
  include ModelProviderSettingsJourney

  AUTH = ModelProviders::CodexAuthorization

  class ProviderResponse
    Response = Data.define(:status, :body, :error)

    def initialize(body)
      @response = Response.new(status: 200, body: body.to_json, error: nil)
    end

    def post(_url, headers:, body:)
      @response
    end
  end

  test "subscription progress refreshes the issuing administrator's code and completion" do
    sign_in_for_model_settings(users(:owner))
    click_link "Configure model providers"
    click_link "OpenAI Codex"
    assert_button "Connect", disabled: false
    assert_button "Enable provider", disabled: false
    assert_button "Disable provider", disabled: true
    assert_current_path admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_models_omit_provider_status
    within "section[aria-label='Subscription']" do
      assert_text "No subscription connected"
      assert_button "Connect"
      assert_no_button "Disconnect"
    end
    capture_authorization_layout("initial")

    click_button "Connect"
    assert_current_path admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_selector "turbo-frame#provider_authorization", count: 1
    assert_button "Connect"
    assert_no_button "Disconnect"
    assert_text "Preparing sign-in. Your authorization code will appear here shortly."
    session = ModelProviderOAuthSession.find_by!(account: accounts(:cybros), provider_id: AUTH::PROVIDER_ID)
    assert_predicate session, :pending?
    policy = ModelProviderConfig.find_by!(account: accounts(:cybros), provider_id: AUTH::PROVIDER_ID)
    refute_predicate policy, :enabled?

    advance_authorization(session, device_auth_id: "synthetic-device-handle", user_code: "BROWSER-CODE", interval: "5")
    within "turbo-frame#provider_authorization" do
      assert_field "Authorization code", with: "BROWSER-CODE", readonly: true
      assert_link "Open authorization page", href: AUTH.verification_url
      assert_no_link "Back to dashboard"
    end
    assert_current_path admin_model_provider_path(AUTH::PROVIDER_ID)
    refute_includes page.html, "synthetic-device-handle"
    capture_authorization_layout("pending")

    click_button "Connect"
    within "section[aria-label='Subscription']" do
      assert_field "Authorization code", with: "BROWSER-CODE", readonly: true
      assert_no_button "Disconnect"
      assert_no_text "Sign-in status"
    end
    assert_equal session.public_id, ModelProviderOAuthSession.nonterminal.find_by!(
      account: accounts(:cybros), provider_id: AUTH::PROVIDER_ID).public_id
    assert_current_path admin_model_provider_path(AUTH::PROVIDER_ID)

    advance_authorization(session, authorization_code: "synthetic-grant", code_challenge: "synthetic-challenge",
      code_verifier: "synthetic-verifier")
    advance_authorization(session, access_token: "synthetic-access", refresh_token: "synthetic-refresh",
      id_token: id_token, expires_in: 86_400)

    within "turbo-frame#provider_authorization" do
      assert_text "Subscription connected"
      assert_no_field "Authorization code"
      assert_no_link "Open authorization page"
      assert_no_link "Back to dashboard"
    end
    assert_current_path admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_models_omit_provider_status
    within "turbo-frame#provider_authorization" do
      assert_no_selector "h2", text: "Sign-in status"
      assert_no_text "This sign-in finished."
      assert_no_link "Manage models"
      assert_button "Disconnect"
      assert_no_button "Connect"
      assert_no_button "Start over"
      assert_no_link "Back to dashboard"
    end
    assert_predicate session.reload, :completed?
    assert_predicate policy.reload, :enabled?
    assert_button "Enable provider", disabled: true
    assert_button "Disable provider", disabled: false
    assert_equal "synthetic-access", ModelProviderCredential.find_by!(
      account: accounts(:cybros), provider_id: AUTH::PROVIDER_ID).secret
    refute_includes page.html, "synthetic-access"
    refute_includes page.html, "synthetic-refresh"
    within "section[aria-label='Subscription']" do
      assert_text "Subscription connected"
      assert_button "Disconnect"
    end
    capture_authorization_layout("complete")
    confirm_through_dialog { click_button "Disconnect" }
    assert_text "No subscription connected"
    assert_current_path admin_model_provider_path(AUTH::PROVIDER_ID)
    assert_button "Enable provider", disabled: true
    assert_button "Disable provider", disabled: false
    assert_models_omit_provider_status
    assert_nil ModelProviderCredential.find_by(account: accounts(:cybros), provider_id: AUTH::PROVIDER_ID)
    assert_button "Connect"
    assert_no_button "Disconnect"
    assert_no_text "This sign-in finished."
    within "nav[aria-label='Back']" do
      click_link "Model providers"
    end
    assert_current_path admin_model_providers_path
  end

  private

    def capture_authorization_layout(state)
      assert_no_horizontal_overflow
      save_model_settings_screenshot("subscription-#{state}", full_page: true)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
      assert_equal 390, page.evaluate_script("window.innerWidth")
      assert_matches_style find(".drawer-side", visible: :all), opacity: "0"
      assert_no_horizontal_overflow
      find("section[aria-label='Subscription']").scroll_to(:center)
      save_model_settings_screenshot("subscription-#{state}-mobile-390", full_page: true)
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      assert_matches_style find(".drawer-side", visible: :all), opacity: "1"
    end

    def advance_authorization(session, **body)
      result = AUTH::Advance.call(session: session.reload, client: ProviderResponse.new(body))
      assert_includes [:applied, :installed], result.outcome
    end

    def id_token
      claims = { "https://api.openai.com/auth" => { "chatgpt_account_id" => "synthetic-browser-account" } }
      "header.#{Base64.urlsafe_encode64(claims.to_json, padding: false)}.signature"
    end
end
