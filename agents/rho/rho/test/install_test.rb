require "test_helper"

# THE INSTALLED PREFIX: the receipt reader the
# install verbs and the doctor share, and the prefix as a protected root
# — the wrapper, the portable Ruby, vendor/bundle and libexec/install.sh
# join the incubation deny set, with the nesting rule collapsing a home
# that sits inside it.
class InstallTest < Minitest::Test
  def with_prefix
    Dir.mktmpdir("rho-prefix") do |dir|
      prefix = File.realpath(dir)
      yield prefix, { "RHO_PREFIX" => prefix }
    end
  end

  def test_no_prefix_means_not_installed
    assert_nil Rho::Install.prefix({})
    assert_nil Rho::Install.prefix({ "RHO_PREFIX" => "  " })
    refute Rho::Install.installed?({})
    assert_nil Rho::Install.receipt({})
    assert_nil Rho::Install.protected_root({ "RHO_PREFIX" => "/nonexistent/rho" })
  end

  def test_the_receipt_is_read_as_a_hash_or_nil
    with_prefix do |prefix, env|
      refute Rho::Install.installed?(env), "a prefix without a receipt is not an install"
      File.write(File.join(prefix, "receipt.json"), JSON.generate("profile" => "full", "tools" => { "rg" => { "version" => "15.2.0" } }))
      assert Rho::Install.installed?(env)
      assert_equal "full", Rho::Install.receipt(env)["profile"]
      assert_equal File.join(prefix, "libexec", "install.sh"), Rho::Install.installer_path(env)
      File.write(File.join(prefix, "receipt.json"), "not json")
      assert_nil Rho::Install.receipt(env)
    end
  end

  def test_exec_refuses_outside_an_install
    error = assert_raises(Rho::ConfigurationError) { Rho::Install.exec_installer("--update", env: {}) }
    assert_match(/not an installed rho/, error.message)
    assert_match(/rolled with `git pull`/, error.message, "a checkout under bundle exec is the developer's own pull")
    with_prefix do |prefix, env|
      File.write(File.join(prefix, "receipt.json"), "{}")
      error = assert_raises(Rho::ConfigurationError) { Rho::Install.exec_installer("--update", env: env) }
      assert_match(%r{libexec/install\.sh is missing}, error.message)
    end
  end

  def test_the_prefix_joins_the_protected_roots_and_subsumes_a_home_inside_it
    with_prefix do |prefix, env|
      outside = Dir.mktmpdir("rho-home")
      begin
        home = Rho::Home.resolve(base_url: "https://nexus.example", root: outside)
        with_env(env) do
          roots = Rho.protected_roots(home)
          assert_includes roots, prefix
          refute_includes roots, File.realpath(outside), "the home's own entry is never a root: its members are"
          home.protected_members.each { |member| assert_includes roots, Rho.spelled(member), member }
          assert_includes roots, File.join(File.realpath(outside), "settings.json")
          assert_includes roots, File.realpath(Rho.root)
        end
        inside = Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(prefix, "home"))
        FileUtils.mkdir_p(inside.root)
        with_env(env) do
          roots = Rho.protected_roots(inside)
          assert_includes roots, prefix
          refute_includes roots, inside.root, "a home under the prefix is the prefix's"
          inside.protected_members.each { |member| refute_includes roots, Rho.spelled(member), "#{member} is the prefix's" }
        end
        with_env({ "RHO_PREFIX" => nil }) do
          refute_includes Rho.protected_roots(home), prefix, "no prefix, no fourth root"
        end
      ensure
        FileUtils.rm_rf(outside)
      end
    end
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
