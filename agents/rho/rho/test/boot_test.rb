require "test_helper"
require "rho/boot"

# THE BOOT ACCELERATOR: the cache lives under the
# home (or where RHO_BOOTSNAP_CACHE_DIR points), keyed on the Ruby, the
# arch, the resolved code root and the lock; the chain is 0700; the off
# switch and an unwritable cache are both a quiet no-op.
class BootTest < Minitest::Test
  def with_tmp
    Dir.mktmpdir("rho-boot") { |dir| yield File.realpath(dir) }
  end

  def test_the_cache_root_is_the_homes_cache_unless_the_environment_names_one
    with_tmp do |dir|
      assert_equal File.join(dir, "cache", "bootsnap"), Rho::Boot.cache_root({ "RHO_HOME" => dir })
      assert_equal File.join(dir, "elsewhere"),
        Rho::Boot.cache_root({ "RHO_HOME" => dir, "RHO_BOOTSNAP_CACHE_DIR" => File.join(dir, "elsewhere") })
      assert_equal File.expand_path("~/.rho/cache/bootsnap"), Rho::Boot.cache_root({ "RHO_HOME" => "" })
    end
  end

  def test_the_key_is_stable_and_moves_with_the_code_root_and_the_lock
    with_tmp do |dir|
      assert_equal Rho::Boot.key, Rho::Boot.key
      assert_equal Rho::Boot::KEY_LENGTH, Rho::Boot.key.length
      refute_equal Rho::Boot.key, Rho::Boot.key(root: dir), "a moved root gets a fresh directory"
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n")
      moved = Rho::Boot.key(root: dir)
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n  changed\n")
      refute_equal moved, Rho::Boot.key(root: dir), "a changed gem set gets a fresh directory"
    end
  end

  def test_setup_creates_the_chain_private_and_answers_the_directory
    with_tmp do |dir|
      home = File.join(dir, "home")
      directory = Rho::Boot.setup!({ "RHO_HOME" => home })
      skip "bootsnap is not in this bundle" if directory.nil? && !defined?(::Bootsnap)

      assert_equal File.join(home, "cache", "bootsnap", Rho::Boot.key), directory
      [home, File.join(home, "cache"), File.join(home, "cache", "bootsnap"), directory].each do |path|
        assert_equal 0o700, File.stat(path).mode & 0o777, "#{path} is not private"
      end
    end
  end

  def test_the_off_switch_and_an_unwritable_cache_are_no_ops
    with_tmp do |dir|
      assert_nil Rho::Boot.setup!({ "RHO_HOME" => dir, "RHO_NO_BOOTSNAP" => "1" })
      refute File.exist?(File.join(dir, "cache")), "off means nothing is created"

      blocked = File.join(dir, "blocked")
      File.write(blocked, "a file where a directory is needed")
      assert_nil Rho::Boot.setup!({ "RHO_HOME" => blocked })
    end
  end

  def test_an_installed_prefix_is_not_development_mode_and_a_checkout_is
    with_tmp do |dir|
      root = File.join(dir, "versions", "0.1.0", "agents", "rho", "rho")
      FileUtils.mkdir_p(root)
      refute Rho::Boot.development?({ "RHO_PREFIX" => dir }, root: root)
      assert Rho::Boot.development?({ "RHO_PREFIX" => dir }, root: Rho::Boot.code_root)
      assert Rho::Boot.development?({}, root: root)
    end
  end
end
