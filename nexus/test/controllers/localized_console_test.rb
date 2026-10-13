require "test_helper"
require_relative "../test_helpers/deployment_test_helper"

class LocalizedConsoleTest < ActionDispatch::IntegrationTest
  include DeploymentTestHelper

  test "brand and nested settings labels resolve from their owning translations at render time" do
    sign_in_as users(:owner)

    with_translations(
      brand: { name: "Horizon" },
      settings: { passwords: { show: { settings: "Réglages", current_password: "Mot de passe actuel" } } }
    ) do
      get settings_password_path

      assert_response :success
      assert_select "title", text: "Réglages · Horizon"
      assert_select "meta[name=application-name][content=Horizon]"
      assert_select "label", text: "Mot de passe actuel"
      assert_equal "Horizon", Setup.new.account_name
    end
  end

  test "system upgrade title and browser messages use the same translated page catalog" do
    sign_in_as users(:owner)

    with_translations(
      admin: { deployments: { show: { system_upgrade: "Mise à niveau du système" } } },
      deployment: { messages: { checking: "Recherche des versions…" } }
    ) do
      Nexus::Deployment::Client.stub(:new, fake_deployment_client) { get admin_deployment_path }

      assert_response :success
      assert_select "h1", text: "Mise à niveau du système"
      assert_select "[data-controller=deployment]" do |nodes|
        assert_equal "Recherche des versions…", JSON.parse(nodes.first["data-deployment-messages-value"]).fetch("checking")
      end
      assert_select "input[name=?][value=?]", "candidate[release]", "2610080750"
    end
  end

  test "translated token labels preserve credential values and safely interpolate user names" do
    sign_in_as users(:owner)
    token_name = "<em>automation</em>"

    with_translations(
      credential_planes: { member: "personnel", platform: "administration" },
      settings: { tokens: { reveal: { save_token_html: "Gardez %{name}." } } },
      clipboard: { copied: "Copié" }
    ) do
      get settings_tokens_path
      assert_select "label", text: /personnel/
      assert_select "input[type=radio][name=?][value=member]", "token[credential_plane]"
      assert_select "input[type=radio][name=?][value=platform]", "token[credential_plane]"

      post settings_tokens_path, params: { token: { name: token_name, current_password: "password" } }

      assert_response :success
      assert_select "p", text: "Gardez #{token_name}."
      assert_select "strong", text: token_name
      assert_select "strong em", count: 0
      assert_select "[data-clipboard-copied-value=?]", "Copié"
    end
  end

  private

    def with_translations(translations)
      original_backend = I18n.backend
      overrides = I18n::Backend::Simple.new
      overrides.eager_load!
      overrides.store_translations(:en, translations)
      I18n.backend = overrides
      yield
    ensure
      I18n.backend = original_backend
    end
end
