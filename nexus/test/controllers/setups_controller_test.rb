require "test_helper"

class SetupsControllerTest < ActionDispatch::IntegrationTest
  test "the unauthenticated surface is state-aware before initialization" do
    Account.destroy_all

    get new_session_path
    assert_redirected_to setup_path

    get root_path
    assert_redirected_to setup_path

    get setup_path
    assert_response :success
  end

  test "setup is closed once the account exists" do
    get setup_path
    assert_redirected_to root_path

    assert_no_difference -> { Account.count } do
      post setup_path, params: { setup: valid_setup_params }
    end
    assert_redirected_to root_path
  end

  test "founding creates the account world and signs the owner in" do
    Account.destroy_all

    assert_difference [-> { Account.count }, -> { Identity.count }], +1 do
      assert_difference -> { User.count }, +2 do
        assert_no_difference -> { Workspace.count } do
          post setup_path, params: { setup: valid_setup_params }
        end
      end
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?

    account = Account.sole
    assert_equal "Acme", account.name
    assert_equal "USD", account.cost_unit
    assert_equal "founder@example.com", account.owner.identity.email

    get root_path
    assert_response :success
  end

  test "advanced setup preserves an explicitly chosen cost unit" do
    Account.destroy_all

    post setup_path, params: { setup: valid_setup_params(cost_unit: " credits ") }

    assert_redirected_to root_path
    assert_equal "credits", Account.sole.cost_unit
  end

  test "a blank advanced cost unit uses the default" do
    Account.destroy_all

    post setup_path, params: { setup: valid_setup_params(cost_unit: " \t ") }

    assert_redirected_to root_path
    assert_equal "USD", Account.sole.cost_unit
  end

  test "an invalid advanced cost unit leaves no founding records" do
    Account.destroy_all
    invalid_unit = "x" * (Account::COST_UNIT_MAX_LENGTH + 1)

    assert_no_difference [-> { Account.count }, -> { Identity.count }, -> { User.count }] do
      post setup_path, params: { setup: valid_setup_params(cost_unit: invalid_unit) }
    end

    assert_response :unprocessable_entity
    assert_select "#setup_cost_unit_errors p.field-error"
    assert_select "input[name='setup[cost_unit]'][value=?]", invalid_unit
  end

  test "invalid input renders field-level errors without creating anything" do
    Account.destroy_all

    assert_no_difference [-> { Account.count }, -> { Identity.count }, -> { User.count }] do
      post setup_path, params: { setup: valid_setup_params(email: "not-an-email") }
    end

    assert_response :unprocessable_entity
    assert_select "p.field-error"
    assert_select "input[name='setup[account_name]'][value='Acme']"
    assert_select "input[name='setup[email]'][value='not-an-email']"
    assert_select "input[name='setup[email]'][aria-invalid='true'][aria-describedby='setup_email_errors']"
    assert_select "#setup_email_errors p.field-error"
    assert_select "input[name='setup[account_name]'][aria-invalid='false']:not([aria-describedby])"
  end

  test "the setup form prefills the default installation name" do
    Account.destroy_all

    get setup_path
    assert_select "input[name='setup[account_name]'][value=?]", Setup.default_account_name
  end

  test "a blank installation name falls back to the default" do
    Account.destroy_all

    post setup_path, params: { setup: valid_setup_params.merge(account_name: "") }

    assert_redirected_to root_path
    assert_equal Setup.default_account_name, Account.sole.name
  end

  test "a setup secret parameter is ignored when none is configured" do
    Account.destroy_all

    assert_difference -> { Account.count }, +1 do
      post setup_path, params: { setup: valid_setup_params, setup_secret: "ignored" }
    end
    assert_redirected_to root_path
  end

  test "a configured setup secret is required and constant-time compared" do
    Account.destroy_all
    ENV["NEXUS_SETUP_SECRET"] = "s3cret"

    assert_no_difference -> { Account.count } do
      post setup_path, params: { setup: valid_setup_params }
    end
    assert_response :unprocessable_entity
    # The typed non-secret values survive the rejection.
    assert_select "input[name='setup[account_name]'][value='Acme']"
    assert_select "input[name='setup[email]'][value='founder@example.com']"

    assert_difference -> { Account.count }, +1 do
      post setup_path, params: { setup: valid_setup_params, setup_secret: "s3cret" }
    end
    assert_redirected_to root_path
  ensure
    ENV.delete("NEXUS_SETUP_SECRET")
  end

  test "the setup page never renders the configured or submitted setup secret" do
    Account.destroy_all
    previous_secret = ENV["NEXUS_SETUP_SECRET"]
    ENV["NEXUS_SETUP_SECRET"] = "synthetic-deployment-setup-secret"

    get setup_path
    assert_response :success
    assert_select "input[name='setup_secret'][type='password']:not([value])"
    refute_includes response.body, ENV["NEXUS_SETUP_SECRET"]

    assert_no_difference -> { Account.count } do
      post setup_path, params: { setup: valid_setup_params, setup_secret: "synthetic-wrong-secret" }
    end
    assert_response :unprocessable_entity
    assert_select "input[name='setup_secret'][type='password']:not([value])"
    refute_includes response.body, "synthetic-wrong-secret"
    refute_includes response.body, ENV["NEXUS_SETUP_SECRET"]

    assert_no_difference -> { Account.count } do
      post setup_path, params: { setup: valid_setup_params(password_confirmation: "mismatch"), setup_secret: ENV["NEXUS_SETUP_SECRET"] }
    end
    assert_response :unprocessable_entity
    assert_select "input[name='setup_secret'][type='password']:not([value])"
    refute_includes response.body, ENV["NEXUS_SETUP_SECRET"]
  ensure
    ENV["NEXUS_SETUP_SECRET"] = previous_secret
  end

  private

    def valid_setup_params(**overrides)
      {
        account_name: "Acme",
        display_name: "Founder",
        email: "founder@example.com",
        password: "correct horse battery",
        password_confirmation: "correct horse battery",
      }.merge(overrides)
    end
end
