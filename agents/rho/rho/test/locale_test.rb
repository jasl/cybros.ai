require "test_helper"

# THE LOCALE DEFAULT, on a Hash rather than the process — because the
# process's own encoding is fixed at boot and cannot be re-tested, and
# because what matters is the rule, not this machine's shell.
class LocaleTest < Minitest::Test
  def test_it_sets_lang_when_no_governing_variable_is_set
    env = {}
    assert_equal({ "LANG" => "C.UTF-8" }, Rho::Locale.ensure_utf8!(env))
    assert_equal "C.UTF-8", env["LANG"]
  end

  # An operator's choice is theirs, even a non-UTF-8 one.
  def test_it_leaves_an_operator_choice_alone
    %w[LANG LC_CTYPE LC_ALL].each do |name|
      env = { name => "zh_CN.GB18030" }
      assert_empty Rho::Locale.ensure_utf8!(env), "#{name} should have been respected"
      assert_equal({ name => "zh_CN.GB18030" }, env)
    end
  end

  # An EMPTY variable is not a choice: `LANG=` exported by a shell that
  # never set one must count as unset, or the default never applies.
  def test_an_empty_variable_counts_as_unset
    env = { "LANG" => "" }
    assert_equal({ "LANG" => "C.UTF-8" }, Rho::Locale.ensure_utf8!(env))
  end

  # The name it picks must be one this system actually has, or the
  # process silently falls back to "C" — US-ASCII again — which is the
  # exact outcome this exists to prevent.
  def test_the_default_is_a_locale_this_system_derives_utf8_from
    derived = IO.popen({ "LANG" => Rho::Locale::DEFAULT, "LC_ALL" => nil, "LC_CTYPE" => nil },
      [RbConfig.ruby, "-e", "print Encoding.default_external"], &:read)
    assert_equal "UTF-8", derived
  end
end
