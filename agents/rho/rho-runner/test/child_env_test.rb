require "test_helper"

class ChildEnvTest < Minitest::Test
  # The suite itself runs under `bundle exec`, so the hazard is live in
  # this very process: what a child would have inherited is exactly what
  # the daemon's children inherited before this helper existed.
  def test_strips_bundlers_trail_and_keeps_the_rest
    env = Rho::Runner::ChildEnv.call

    assert_empty env.keys.grep(/\ABUNDLE_|\ABUNDLER_/),
      "a child would load rho's Gemfile: #{env.keys.grep(/BUNDLE/).inspect}"
    # A RUBYLIB or RUBYOPT that predates Bundler is the person's own and
    # stays; Bundler's additions to them must not.
    refute_match(/bundler/, env.fetch("RUBYOPT", ""))
    refute_match(/bundler/, env.fetch("RUBYLIB", ""))
    assert_equal ENV.fetch("HOME"), env["HOME"]
    assert_equal "1", env["PYTHONUNBUFFERED"]
  end

  def test_without_bundler_the_same_keys_are_dropped_by_name
    current = {
      "PATH" => "/usr/bin", "BUNDLE_GEMFILE" => "/x/Gemfile", "RUBYOPT" => "-rbundler/setup",
      "RUBYLIB" => "/x/lib", "GEM_HOME" => "/x/gems", "LANG" => "C.UTF-8",
    }
    stripped = current.reject { |key, _| key.match?(Rho::Runner::ChildEnv::BUNDLER_KEYS) }

    assert_equal %w[LANG PATH], stripped.keys.sort
  end

  # Rho decides the locale after Bundler took its snapshot; the child must
  # see rho's decision, not the machine's absence of one.
  def test_the_current_locale_wins_over_bundlers_snapshot
    snapshot = { "LANG" => "C", "LC_ALL" => "C", "LC_CTYPE" => "C", "PATH" => "/usr/bin" }
    with_bundler_snapshot(snapshot) do
      with_env("LANG" => "C.UTF-8", "LC_ALL" => nil, "LC_CTYPE" => nil) do
        env = Rho::Runner::ChildEnv.call

        assert_equal "C.UTF-8", env["LANG"]
        refute env.key?("LC_ALL")
        refute env.key?("LC_CTYPE")
        assert_equal "/usr/bin", env["PATH"]
      end
    end
  end

  # THE SCRUB: what a THIRD
  # PARTY's long-lived child gets whole under `unsetenv_others: true` —
  # `call` minus every credential-shaped name, rho's own, and Bundler's
  # trail by name on top (a nested `bundle exec` leaves one `call` reads
  # back as the environment Bundler started from). `call` reads Bundler's
  # snapshot, never a variable planted at run time, so the pin reads the
  # result's shape against `call`'s.
  def test_scrubbed_is_call_minus_credential_shaped_rhos_and_bundlers_names
    base = Rho::Runner::ChildEnv.call
    env = Rho::Runner::ChildEnv.scrubbed

    refute_nil env["PATH"]
    assert_equal ENV.fetch("HOME"), env["HOME"]
    assert_equal "1", env["PYTHONUNBUFFERED"]
    assert_empty env.keys - base.keys, "the scrub adds nothing"
    assert_equal base.slice(*env.keys), env, "a kept variable keeps its value"
    withheld = lambda do |name|
      name.match?(Rho::Runner::Secrets::CREDENTIAL_SHAPED) || name.start_with?("RHO_", "BUNDLE_", "BUNDLER_") ||
        name.match?(Rho::Runner::ChildEnv::BUNDLER_KEYS)
    end
    assert_empty env.keys.select(&withheld), "a credential-shaped, rho or Bundler name reached the child"
    assert_empty (base.keys - env.keys).reject(&withheld), "a name outside the rule was dropped"
  end

  def test_scrubbed_takes_the_current_environment_it_is_given_for_the_locale
    with_env("LANG" => "C.UTF-8", "LC_ALL" => nil) do
      env = Rho::Runner::ChildEnv.scrubbed({ "LANG" => "zh_CN.UTF-8", "GH_TOKEN" => "x" })
      assert_equal "zh_CN.UTF-8", env["LANG"], "the locale is the current environment's, as `call` takes it"
      refute env.key?("GH_TOKEN")
    end
  end

  private

    def with_bundler_snapshot(snapshot)
      original = Bundler.method(:with_unbundled_env)
      Bundler.define_singleton_method(:with_unbundled_env) { snapshot }
      yield
    ensure
      Bundler.define_singleton_method(:with_unbundled_env, original)
    end

    def with_env(pairs)
      saved = pairs.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
