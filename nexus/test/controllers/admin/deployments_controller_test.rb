require "test_helper"
require_relative "../../test_helpers/deployment_test_helper"

class Admin::DeploymentsControllerTest < ActionDispatch::IntegrationTest
  include DeploymentTestHelper

  setup do
    @client = fake_deployment_client
    sign_in_as users(:owner)
  end

  test "the page displays configured repositories and frozen candidate images without checking the registry" do
    Nexus::Deployment::Client.stub(:new, @client) { get admin_deployment_path }

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal [{ operation: :status }], @client.calls
    assert_select "h1", text: "System upgrade"
    assert_select "h2", text: "Image sources"
    assert_select "h2", text: "Upgrade checks"
    assert_select "[role=status]", text: "Ready to upgrade"
    assert_select "li[data-preflight-check=image_store_space]", text: /Warning/
    assert_includes response.body, "registry.example/nexus"
    assert_select "button", text: "Check for updates"
    assert_select "input[type=checkbox][name=?][checked]", "release_check[backup]"
    assert_select "button:not([disabled])", text: "Start upgrade"
    assert_select "input[name=?][value=?]", "candidate[release]", "2610080750"
    assert_select "a[href=?]", "https://example.test/source", text: "View source"
  end

  test "ordinary forms check a release then redirect to the accepted receipt" do
    Nexus::Deployment::Client.stub(:new, @client) do
      post admin_deployment_release_check_path
      assert_response :see_other
      assert_equal true, @client.calls.last.fetch(:backup)
      assert_redirected_to admin_deployment_path
      post admin_deployment_upgrades_path, params: { candidate: deployment_release, idempotency_key: IDEMPOTENCY_KEY }
      assert_response :see_other
      assert_equal true, @client.calls.last.fetch(:backup)
      assert_redirected_to admin_deployment_upgrade_path(OPERATION_ID)
      follow_redirect!
    end
    assert_response :success
    assert_select "h2", text: "Upgrade progress"
    assert_select "[data-deployment-target=phase]", text: "Preparing images"
    assert_select "button[disabled]", text: "Start upgrade"
  end

  test "ordinary forms preserve an unchecked backup choice and the receipt names the skipped backup" do
    Nexus::Deployment::Client.stub(:new, @client) do
      post admin_deployment_release_check_path, params: { release_check: { backup: "false" } }
      assert_response :see_other
      assert_equal false, @client.calls.last.fetch(:backup)
      follow_redirect!
      assert_select "input[type=checkbox][name=?]:not([checked])", "release_check[backup]"
      assert_select "input[name=backup][value=false]"

      post admin_deployment_upgrades_path, params: { candidate: deployment_release,
        idempotency_key: IDEMPOTENCY_KEY, backup: "false" }
      assert_response :see_other
      assert_equal false, @client.calls.last.fetch(:backup)
      follow_redirect!
      assert_select "section[aria-labelledby=database-backup-heading]:not([hidden])" do
        assert_select "p", text: "Skipped for this upgrade"
        assert_select "dl[hidden]"
      end
    end
  end

  test "the browser JSON command uses its current Human rather than a supplied actor" do
    Nexus::Deployment::Client.stub(:new, @client) do
      post admin_deployment_upgrades_path,
        params: { candidate: deployment_release, idempotency_key: IDEMPOTENCY_KEY,
          actor_public_id: users(:member).public_id }, as: :json
    end
    assert_response :accepted
    assert_equal users(:owner).public_id, response.parsed_body.dig("upgrade", "actor_public_id")
    assert_equal admin_deployment_upgrade_path(OPERATION_ID), URI(response.location).path
  end

  test "a blocked preflight keeps its reasons and next steps visible without enabling the candidate" do
    @client.state = @client.state.with(preflight: Nexus::Deployment::Preflight.from_h(deployment_preflight(ready: false)))
    Nexus::Deployment::Client.stub(:new, @client) do
      post admin_deployment_release_check_path, as: :json
      assert_response :success
      refute response.parsed_body.dig("deployment", "preflight", "ready")
      get admin_deployment_path
      assert_response :success
      assert_select "[role=status]", text: "Upgrade blocked"
      assert_select "li[data-preflight-check=installation_space]" do
        assert_select "p", text: /Free space on the installation volume and check again\./
        assert_select "dd", text: "1,048,576 bytes"
        assert_select "dd", text: "2,097,152 bytes"
      end
      assert_select "button[disabled]", text: "Start upgrade"
      assert_select "button:not([disabled])", text: "Check for updates"

      @client.state = @client.state.with(candidate: nil)
      get admin_deployment_path
      assert_select "[role=status]", text: "Upgrade blocked"
      assert_select "button", text: "Start upgrade", count: 0
    end
    refute @client.calls.any? { |call| call.fetch(:operation) == :upgrade }
  end

  test "a candidate without a preflight cannot be started" do
    @client.state = @client.state.with(preflight: nil)
    Nexus::Deployment::Client.stub(:new, @client) { get admin_deployment_path }

    assert_response :success
    assert_select "p", text: "Run a release check to see whether this installation is ready to upgrade."
    assert_select "button[disabled]", text: "Start upgrade"
  end

  test "saved upgrade backups expose only metadata and distinguish retention without a download or restore control" do
    [true, false].each do |available|
      @client.back_up(deployment_backup(available: available))
      @client.complete
      Nexus::Deployment::Client.stub(:new, @client) { get admin_deployment_upgrade_path(OPERATION_ID) }

      assert_response :success
      assert_select "section[aria-labelledby=database-backup-heading]:not([hidden])" do
        assert_select "h3", text: "Upgrade database backup"
        assert_select "p", text: available ? "Available on the installation host" : "No longer retained"
        assert_select "dd", text: "2026-10-08T09:30:02Z"
        assert_select "dd", text: "1,048,576 bytes"
        assert_select "p", text: /database-only backup excludes uploaded files/
        assert_select "a, form", count: 0
      end
    end
  end

  test "unsupported and unavailable installations have no actionable upgrade controls" do
    Nexus::Deployment::Client.stub(:new, Nexus::Deployment::Client.new(socket_path: nil)) do
      get admin_deployment_path
    end
    assert_response :success
    assert_select "h2", text: "Online upgrade is not configured"
    assert_select "button", text: "Start upgrade", count: 0
    assert_select "button", text: "Check for updates", count: 0

    @client.failure = deployment_error
    Nexus::Deployment::Client.stub(:new, @client) { get admin_deployment_path }
    assert_response :service_unavailable
    assert_select "[role=alert]", text: "The updater could not complete this request."
    assert_select "button", text: "Start upgrade", count: 0
    assert_select "a", text: "Try again"
  end

  test "a cached candidate never makes an active upgrade actionable or an unsafe source URL clickable" do
    @client.state = @client.state.with(
      active_operation: @client.upgrade_receipt,
      candidate: @client.state.candidate.with(source_url: "javascript:alert(1)")
    )
    Nexus::Deployment::Client.stub(:new, @client) { get admin_deployment_path }

    assert_response :success
    assert_select "button[disabled]", text: "Start upgrade"
    assert_select "button[disabled]", text: "Check for updates"
    assert_select "a", text: "View source", count: 0
  end

  test "a completed installation does not offer to install the same selected images again" do
    @client.complete
    Nexus::Deployment::Client.stub(:new, @client) { get admin_deployment_path }

    assert_response :success
    assert_select "p", text: "This release is already installed."
    assert_select "button", text: "Start upgrade", count: 0
    assert_select "a:not([hidden])", text: "Reload Nexus"
  end

  test "HTML commands retain the normal CSRF boundary" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    Nexus::Deployment::Client.stub(:new, @client) do
      post admin_deployment_upgrades_path, params: { candidate: deployment_release, idempotency_key: IDEMPOTENCY_KEY },
        headers: { "Sec-Fetch-Site" => "cross-site" }
      assert_response :unprocessable_entity
      assert_empty @client.calls
      post admin_deployment_upgrades_path, params: { candidate: deployment_release, idempotency_key: IDEMPOTENCY_KEY },
        headers: { "Sec-Fetch-Site" => "same-origin" }
      assert_response :see_other
    end
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "ordinary and signed-out Humans cannot enter or submit the upgrade page" do
    sign_out
    Nexus::Deployment::Client.stub(:new, @client) do
      get admin_deployment_path
      assert_response :redirect
      post admin_deployment_release_check_path
      assert_response :redirect
      sign_in_as users(:member)
      get admin_deployment_path
      assert_response :forbidden
      post admin_deployment_upgrades_path, params: { candidate: deployment_release, idempotency_key: IDEMPOTENCY_KEY }
      assert_response :forbidden
    end
    assert_empty @client.calls
  end
end
