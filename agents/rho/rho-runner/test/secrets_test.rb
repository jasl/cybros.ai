require "test_helper"

# THE ROW-SECRETS RULE, one for every protocol table:
# a `${NAME}` in a row's value expands ONCE from the daemon's environment
# and every expansion is a secret; an unset name is the row's fault by
# NAME, never by value; a literal typed under a credential-shaped key is
# a secret when it is long enough to be one. rho-mcp's `mcp_servers` and
# the ACP client's `acp_agents` parse through this and hold no copy.
class SecretsTest < Minitest::Test
  Secrets = Rho::Runner::Secrets

  def test_expansion_answers_the_text_and_every_expanded_value_as_a_secret
    text, secrets = Secrets.expand("Bearer ${REMOTE_TOKEN} via ${PROXY}",
      { "REMOTE_TOKEN" => "rtsecret-0123456789", "PROXY" => "corp" })

    assert_equal "Bearer rtsecret-0123456789 via corp", text
    assert_equal ["rtsecret-0123456789", "corp"], secrets, "every expansion is a secret; the floor is Redact's"
  end

  def test_a_value_with_no_expansion_is_itself_and_no_secret
    assert_equal ["literal-key-123", []], Secrets.expand("literal-key-123", {})
  end

  # The fault names the VARIABLE, so a sentence built from it can name the
  # key and never a value; an empty variable is unset, as `Config` reads
  # one (`RHO_BIND=` disables an override).
  def test_an_unset_or_empty_name_is_the_fault_naming_the_variable
    error = assert_raises(Secrets::Unset) { Secrets.expand("${FX_TOKEN}", {}) }
    assert_equal "FX_TOKEN", error.variable
    assert_kind_of Rho::Runner::Error, error
    assert_equal "FX_TOKEN", assert_raises(Secrets::Unset) { Secrets.expand("x${FX_TOKEN}", { "FX_TOKEN" => "" }) }.variable
  end

  # sec-4: `OPENAI_API_KEY: "sk-…"` typed into the file is a secret like an
  # expansion is; a short literal (a flag, a port) under such a key is not,
  # because masking it would erase the text around it; a long literal
  # under a plain key is the person's, not a secret.
  def test_a_literal_under_a_credential_shaped_key_is_a_secret_when_long_enough
    assert Secrets.literal_credential?("OPENAI_API_KEY", "sk-literal-1234567890")
    assert Secrets.literal_credential?(:db_passwd, "hunter22hunter22")
    refute Secrets.literal_credential?("DEBUG_KEY", "1")
    refute Secrets.literal_credential?("PORT", "80808080")
    refute Secrets.literal_credential?("FX_TOKEN", "1234567"), "seven bytes is under the redactor's floor"
  end

  def test_the_two_shapes
    assert_match Secrets::EXPANSION, "${A_1}"
    refute_match Secrets::EXPANSION, "${1A}"
    refute_match Secrets::EXPANSION, "$A"
    %w[KEY password Passwd SECRET token credential].each { |word| assert_match Secrets::CREDENTIAL_SHAPED, "x_#{word}_y" }
    refute_match Secrets::CREDENTIAL_SHAPED, "HOME"
  end
end
