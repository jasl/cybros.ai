require "test_helper"

# REDACTION BY VALUE (shared by MCP and ACP clients): every expanded secret erased
# wherever it appears, longest first, short values left alone, the SDK's families on
# top.
class RedactTest < Minitest::Test
  def test_every_occurrence_of_each_secret_is_masked_longest_first
    redact = Rho::Runner::Redact.new(["ghp_abcdef123456", "ghp_abcdef123456-extended", "short"])
    text = "token ghp_abcdef123456-extended then ghp_abcdef123456 and short and sk-abcdef12345"
    assert_equal "token ••• then ••• and short and [REDACTED]", redact.call(text)
    assert_equal ["ghp_abcdef123456-extended", "ghp_abcdef123456"], redact.secrets, "short values are not secrets"
  end

  def test_nil_and_non_strings_are_text
    assert_equal "", Rho::Runner::Redact.new.call(nil)
    assert_equal "42", Rho::Runner::Redact.new(["0123456789"]).call(42)
  end

  # THE LIVE SET: a source read at every call —
  # a rotated token joins after construction — erased with the static set
  # longest first, the floor applied, in text and in a structure.
  def test_the_live_set_is_read_at_every_call_and_erased_with_the_static_set
    live = Struct.new(:secret_values).new([])
    redact = Rho::Runner::Redact.new(["header-secret-0123"], live: live)
    assert_equal "Bearer at-first-0123456789 and •••", redact.call("Bearer at-first-0123456789 and header-secret-0123")
    live.secret_values = ["at-first-0123456789", "at-first-0123456789-longer", "tiny"]
    assert_equal "Bearer ••• then ••• and ••• tiny",
      redact.call("Bearer at-first-0123456789-longer then at-first-0123456789 and header-secret-0123 tiny")
    assert_equal({ "token" => "•••", "n" => 1 }, redact.structure({ "token" => "at-first-0123456789", "n" => 1 }))
    assert_equal ["header-secret-0123"], redact.secrets, "the static set is what `secrets` answers"
  end

  # THE VALUE SET ALONE: a text
  # a PERSON must use verbatim — the authorization URL, whose random
  # `state` and `code_challenge` are free to contain `sk-`-like bytes —
  # is erased of the row's and the live set's values and never of the
  # SDK's families; `call` is that plus the families.
  def test_secrets_only_erases_the_values_and_never_the_families
    live = Struct.new(:secret_values).new(["at-live-0123456789"])
    redact = Rho::Runner::Redact.new(["header-secret-0123"], live: live)
    url = "https://as.example/authorize?state=sk-Ab12&code_challenge=rt-Cd34&h=header-secret-0123&t=at-live-0123456789"
    assert_equal "https://as.example/authorize?state=sk-Ab12&code_challenge=rt-Cd34&h=•••&t=•••", redact.secrets_only(url)
    assert_equal "https://as.example/authorize?state=[REDACTED]&code_challenge=[REDACTED]&h=•••&t=•••", redact.call(url)
    assert_equal "", redact.secrets_only(nil)
  end

  # A structure walked: keys are text too (a secret under a key is a
  # secret), and a secret JSON would escape is found in its own spelling.
  def test_a_structure_is_walked_never_reserialized
    redact = Rho::Runner::Redact.new(['quote"secret\\x'])
    assert_equal({ "•••" => ["•••", 1, nil, true] },
      redact.structure({ 'quote"secret\\x' => ['quote"secret\\x', 1, nil, true] }))
  end

  def test_a_structure_uses_one_live_set_and_the_next_call_observes_rotation
    first = 'quote"secret\\x'
    rotated = 'next"secret\\value'
    values = [first]
    reads = 0
    live = Object.new
    live.define_singleton_method(:secret_values) { reads += 1; values }
    redact = Rho::Runner::Redact.new(["static-secret-value"], live: live)
    input = { first => [first, { "token" => rotated }, 1, nil, true, false], 7 => "static-secret-value", :kind => :kept }

    assert_equal({ "•••" => ["•••", { "token" => rotated }, 1, nil, true, false], 7 => "•••", :kind => :kept },
      redact.structure(input))
    assert_equal 1, reads, "the live source supplies one set for the whole structure"

    values = [rotated]
    assert_equal({ first => [first, { "token" => "•••" }, 1, nil, true, false], 7 => "•••", :kind => :kept },
      redact.structure(input))
    assert_equal 2, reads, "the next public call reads the rotated set"
    assert_equal first, input.keys.first
    assert_equal first, input.fetch(first).first
    assert_equal rotated, input.fetch(first).fetch(1).fetch("token")
  end

  def test_masked_keeps_the_names_and_never_a_value
    assert_equal({ "FX_TOKEN" => "•••", "Authorization" => "•••" },
      Rho::Runner::Redact.masked("FX_TOKEN" => "abc", "Authorization" => "Bearer x"))
  end
end
