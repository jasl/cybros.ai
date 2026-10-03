require_relative "../../../nexus/test/test_helper"
require_relative "dev_import"
require "tmpdir"

# The development door: auth.json imports directly as the codex credential — development/test only,
# no HTTP construction point, tokens never printed. The device-start flow stays the only production
# path.
class E2E::Manual::CodexAuthorization::DevImportTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @directory = Dir.mktmpdir
  end

  teardown { FileUtils.remove_entry(@directory) }

  def fake_jwt(claims)
    payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
    "eyJhbGciOiJub25lIn0.#{payload}.sig"
  end

  def write_auth_file(tokens)
    path = File.join(@directory, "auth.json")
    File.write(path, JSON.generate("auth_mode" => "chatgpt", "tokens" => tokens))
    path
  end

  test "the file's token pair installs as the codex credential with the JWT's own expiry" do
    exp = 30.minutes.from_now
    path = write_auth_file(
      "access_token" => fake_jwt("exp" => exp.to_i),
      "refresh_token" => "refresh-secret",
      "account_id" => "acct-1"
    )

    result = E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: path)

    assert_equal :imported, result.outcome
    credential = result.credential
    assert_equal "codex_subscription", credential.provider_id
    assert_equal "oauth_tokens", credential.material_kind
    assert_equal "acct-1", credential.provider_account_identity
    assert_in_delta exp.to_i, credential.expires_at.to_i, 2
  end

  test "a re-import replaces the credential it sees — the CAS never strands a stale row" do
    path = write_auth_file(
      "access_token" => fake_jwt("exp" => 30.minutes.from_now.to_i),
      "refresh_token" => "refresh-1"
    )
    first = E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: path)
    assert_equal :imported, first.outcome

    second = E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: path)

    assert_equal :imported, second.outcome
    assert_operator second.credential.generation, :>, first.credential.generation
  end

  test "absence and malformation refuse without touching anything" do
    assert_equal :no_auth_file,
      E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: nil).outcome
    assert_equal :no_auth_file,
      E2E::Manual::CodexAuthorization::DevImport.call(
        account: @account, path: "/nonexistent/auth.json"
      ).outcome

    path = File.join(@directory, "auth.json")
    File.write(path, "{not json")
    assert_equal :malformed_auth_file,
      E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: path).outcome

    empty = write_auth_file("access_token" => "", "refresh_token" => "r")
    assert_equal :malformed_auth_file,
      E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: empty).outcome
    assert_equal 0, ModelProviderCredential.where(provider_id: "codex_subscription").count
  end

  test "a pending OAuth session holds the door — importing over a frozen triple would poison the lane" do
    ModelProviders::EnableLane.call(
      account: @account, provider_id: "codex_subscription", expected_lock_version: nil
    )
    accepted = ModelProviders::CodexAuthorization::AcceptSession.call(
      account: @account, issuing_user: users(:member), kind: "device_start"
    )
    assert_predicate accepted, :accepted?, "the guard needs a real pending session"
    path = write_auth_file(
      "access_token" => fake_jwt("exp" => 30.minutes.from_now.to_i),
      "refresh_token" => "r"
    )

    result = E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: path)

    assert_equal :oauth_session_in_progress, result.outcome
    assert_equal 0, ModelProviderCredential.where(provider_id: "codex_subscription").count
  end

  test "shape surprises refuse or fall back — never a backtrace" do
    array_top = File.join(@directory, "auth.json")
    File.write(array_top, JSON.generate([{ "tokens" => {} }]))
    assert_equal :malformed_auth_file,
      E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: array_top).outcome

    scalar_payload = write_auth_file(
      "access_token" => "a.MTIz.b", "refresh_token" => "r"
    )
    result = E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: scalar_payload)
    assert_equal :imported, result.outcome
    assert_in_delta 15.minutes.from_now.to_i, result.credential.expires_at.to_i, 5,
      "a JWT payload that is valid JSON but not an object takes the conservative window"
  end

  test "an unparsable access token still imports with a conservative window" do
    path = write_auth_file(
      "access_token" => "opaque-not-a-jwt", "refresh_token" => "r"
    )

    result = E2E::Manual::CodexAuthorization::DevImport.call(account: @account, path: path)

    assert_equal :imported, result.outcome
    assert_in_delta 15.minutes.from_now.to_i, result.credential.expires_at.to_i, 5
  end

  test "production refuses before inspecting the auth file or querying credentials" do
    Rails.stub(:env, "production".inquiry) do
      File.stub(:exist?, ->(*) { flunk "production must not inspect the auth file" }) do
        assert_no_queries do
          result = E2E::Manual::CodexAuthorization::DevImport.call(
            account: @account, path: "/unused/auth.json"
          )

          assert_equal :not_development, result.outcome
          assert_nil result.credential
        end
      end
    end
  end
end
