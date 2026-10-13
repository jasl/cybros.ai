require "test_helper"

# A running extension's browser module: one directory per extension, entered
# at its index.js, recorded only when the factory commits.
class WebuiModuleTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-webui-module")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def extension(name, &block)
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) { |api| block.call(api) }
    end
  end

  def host(settings = {}) = RhoTest.host.with(config: Rho::Config.from_hash(settings))

  def api(name = "test.module", settings = {})
    Rho::Extensions::Api.new(host: host(settings), extension_name: name, source: "<test>")
  end

  def browser_module(name)
    directory = File.join(@root, name)
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "index.js"), "export function register(ui) {}\n")
    directory
  end

  def test_registration_records_the_realpath_root_under_an_entry_that_follows_the_directory
    directory = browser_module("module")
    link = File.join(@root, "link")
    File.symlink(directory, link)
    linked = api.register_webui_module(root: link).webui_module
    direct = api.register_webui_module(root: "#{directory}/").webui_module

    assert_equal "test.module", linked.extension
    assert_equal File.realpath(directory), linked.root
    assert_match %r{\A/modules/test\.module/\h{12}/index\.js\z}, linked.entry
    assert_equal "/#{linked.path}index.js", linked.entry
    assert_equal linked.entry, direct.entry
    refute_equal linked.entry, api.register_webui_module(root: browser_module("other")).webui_module.entry
  end

  def test_a_second_module_an_empty_root_and_a_directory_without_index_js_are_refused
    handle = api.register_webui_module(root: browser_module("first"))
    error = assert_raises(Rho::Runner::Extensions::RegistrationError) do
      handle.register_webui_module(root: browser_module("second"))
    end
    assert_includes error.message, "test.module already registered a webui module"

    ["", nil].each do |root|
      error = assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_webui_module(root: root) }
      assert_includes error.message, "register_webui_module needs a non-empty root"
    end

    empty = File.join(@root, "empty")
    FileUtils.mkdir_p(empty)
    error = assert_raises(Rho::Runner::Extensions::RegistrationError) { api.register_webui_module(root: empty) }
    assert_includes error.message, "test.module"
    assert_includes error.message, File.join(empty, "index.js")
  end

  def test_runner_hosts_load_the_same_extension_without_a_module
    owner = extension("test.module") { |handle| handle.register_webui_module(root: browser_module("module")) }
    loaded = Rho::Extensions.load(host: host("mode" => "runner"), extensions: [owner])

    assert_predicate loaded, :ok?
    assert_equal ["test.module"], loaded.extensions.map(&:name)
    assert_equal [], loaded.webui_modules
    assert_predicate Rho::Runner::Extensions::Loader.call(builtin: [owner]), :ok?
  end

  def test_a_factory_that_raises_after_registering_contributes_no_module
    failed = extension("test.failed") do |handle|
      handle.register_webui_module(root: browser_module("failed"))
      raise "broken factory"
    end
    loaded = Rho::Extensions.load(host: host, extensions: [failed])

    assert_equal [], loaded.webui_modules
    assert_equal ["broken factory"], loaded.failures.map(&:message)
  end

  def test_every_committed_extension_may_contribute_its_own_module
    owners = %w[test.first test.second].map do |name|
      extension(name) { |handle| handle.register_webui_module(root: browser_module(name)) }
    end
    loaded = Rho::Extensions.load(host: host, extensions: owners)

    assert_predicate loaded, :ok?
    assert_equal %w[test.first test.second], loaded.webui_modules.map(&:extension)
    assert_equal 2, loaded.webui_modules.map(&:entry).uniq.length
  end
end
