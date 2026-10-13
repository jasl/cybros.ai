require "test_helper"

class Settings::TokensTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:member)
  end

  test "the tokens page lists only the member's own tokens" do
    mine = create_access_token_fixture(user: users(:member), name: "Mine").token
    other = create_access_token_fixture(user: users(:owner), name: "Other").token

    get settings_tokens_path
    assert_response :success
    assert_select "td span.font-medium", text: mine.name
    assert_select "td span.font-medium", text: other.name, count: 0
  end

  test "duplicate token names remain distinguishable by token id" do
    first = create_access_token_fixture(user: users(:member), name: "CI").token
    second = create_access_token_fixture(user: users(:member), name: "CI").token

    get settings_tokens_path

    assert_response :success
    [first, second].each do |token|
      target = "#{token.name} (Token ID #{token.lookup_id})"

      assert_select "tr[data-token-id='#{token.public_id}']" do
        assert_select "code", text: token.lookup_id
        assert_select "button[aria-label=?][data-turbo-confirm=?]",
          "Revoke #{target}",
          "Revoke #{target}? Automation using it stops authenticating immediately.",
          text: "Revoke"
      end
    end
  end

  test "minting reveals the secret exactly once under no-store" do
    assert_difference -> { users(:member).access_tokens.count }, 1 do
      post settings_tokens_path, params: {
        token: { current_password: "password", name: "CI" },
      }
    end

    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "input[readonly][value^='sk-cybros-api-v1-']"
    assert_select "strong", text: "CI"
    assert_select "code", text: users(:member).access_tokens.order(:id).last.lookup_id

    get settings_tokens_path
    assert_select "input[value^='sk-cybros-api-v1-']", count: 0
  end

  test "minting defaults to a member-plane token" do
    post settings_tokens_path, params: {
      token: {
        current_password: "password",
        name: "CI",
      },
    }

    assert_response :created
    assert_predicate users(:member).access_tokens.order(:id).last, :member_plane?
  end

  test "the create form requires the current password and ignores an unrelated token query value" do
    get settings_tokens_path(token: "x")

    assert_response :success
    assert_select "input[type='password'][name='token[current_password]'][required]"
  end

  test "minting without the current password creates no token" do
    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path, params: { token: { name: "CI" } }
    end

    assert_response :unprocessable_entity
  end

  test "minting with the wrong current password creates no token" do
    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path, params: {
        token: { current_password: "wrong", name: "CI" },
      }
    end

    assert_response :unprocessable_entity
  end

  test "minting with a null-byte current password returns the ordinary validation response" do
    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path, params: {
        token: { current_password: "pass\0word", name: "CI" },
      }
    end

    assert_response :unprocessable_entity
    assert_select "p.field-error", text: "Current password is invalid"
  end

  test "a member cannot mint a platform token and sees no such option" do
    get settings_tokens_path
    assert_response :success
    assert_select "input#token_plane_member"
    assert_select "input#token_plane_platform", count: 0

    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path, params: {
        token: { current_password: "password", name: "Bad", credential_plane: "platform" },
      }
    end
    assert_response :unprocessable_entity
  end

  test "an administrator mints a platform token from the offered choice" do
    sign_out
    sign_in_as users(:owner)

    get settings_tokens_path
    assert_select "input#token_plane_platform"

    assert_difference -> { users(:owner).access_tokens.count }, 1 do
      post settings_tokens_path, params: {
        token: { current_password: "password", name: "Ops", credential_plane: "platform" },
      }
    end

    assert_response :created
    assert_predicate users(:owner).access_tokens.order(:id).last, :platform_plane?
  end

  test "an oversized note renders an accessible field error" do
    note = "n" * (AccessToken::NOTE_MAX_LENGTH + 1)

    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path, params: {
        token: { current_password: "password", name: "Bad", note: note },
      }
    end

    assert_response :unprocessable_entity
    assert_select "input[name='token[note]'][value=?][aria-invalid='true'][aria-describedby='token_note_errors']", note
    assert_select "#token_note_errors p.field-error", text: "Note is too long (maximum is 2000 characters)"
  end

  test "the tokens list paginates past the page size" do
    11.times do |number|
      create_access_token_fixture(user: users(:member), name: "Token #{number}")
    end

    get settings_tokens_path
    assert_select "tbody tr", count: 10

    get settings_tokens_path(page: 2)
    assert_response :success
    assert_select "tbody tr", count: 1
  end

  test "a failed create keeps only the original query in pagination links" do
    11.times do |number|
      create_access_token_fixture(user: users(:member), name: "Token #{number}")
    end

    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path(context: "kept"), params: {
        authenticity_token: "body-only-token",
        commit: "Create token",
        token: {
          current_password: "password",
          name: "",
          note: "body-only note",
        },
      }
    end

    assert_response :unprocessable_entity
    assert_select "nav[aria-label='Token pages'] a", text: "2" do |links|
      query = Rack::Utils.parse_nested_query(URI.parse(links.first["href"]).query)
      assert_equal({ "context" => "kept", "page" => "2" }, query)
    end
  end

  test "current-password attempts are limited by user across IPs and browser sessions" do
    10.times do |number|
      post settings_tokens_path,
        params: { token: { current_password: "wrong", name: "CI" } },
        headers: { "REMOTE_ADDR" => "192.0.2.#{number + 1}" }
      assert_response :unprocessable_entity
    end

    sign_out
    sign_in_as users(:owner)
    post settings_tokens_path,
      params: { token: { current_password: "wrong", name: "Owner CI" } },
      headers: { "REMOTE_ADDR" => "198.51.100.1" }
    assert_response :unprocessable_entity

    sign_out
    sign_in_as users(:member)
    post settings_tokens_path,
      params: { token: { current_password: "wrong", name: "CI" } },
      headers: { "REMOTE_ADDR" => "203.0.113.1" }

    assert_redirected_to settings_tokens_path
    assert_equal I18n.t("settings.current_password_rate_limited"), flash[:alert]
  end

  test "token issuance shares the current-password limit with other settings commands" do
    10.times do
      patch settings_email_path, params: {
        email: { email: "new@example.com", current_password: "wrong" },
      }
      assert_response :unprocessable_entity
    end

    assert_no_difference -> { AccessToken.count } do
      post settings_tokens_path, params: {
        token: { current_password: "password", name: "CI" },
      }
    end

    assert_redirected_to settings_tokens_path
    assert_equal I18n.t("settings.current_password_rate_limited"), flash[:alert]
  end

  test "revocation stops authentication immediately and is idempotent" do
    credential = create_access_token_fixture(user: users(:member), name: "CI")

    post settings_token_revocation_path(credential.token.public_id)
    assert_redirected_to settings_tokens_path
    assert_nil AccessToken.authenticate_token(credential.secret)

    post settings_token_revocation_path(credential.token.public_id)
    assert_redirected_to settings_tokens_path
  end

  test "another member's token is not revocable" do
    other = create_access_token_fixture(user: users(:owner), name: "Other").token

    post settings_token_revocation_path(other.public_id)
    assert_response :not_found
    assert_not other.reload.revoked?
  end
end
