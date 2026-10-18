require "test_helper"

class ExtensionTest < Minitest::Test
  include WebuiTest

  # The gem ships the page as written: this list is the page.
  def test_registration_points_to_a_complete_browser_bundle
    root = registered_root
    assert_equal File.join(ROOT, "webui"), root
    tree = Dir.glob("**/*", base: root).select { |path| File.file?(File.join(root, path)) }.sort
    assert_includes tree, "index.html"
    assert_includes tree, "app.js"
    %w[kernel/slots.js kernel/outlets.js kernel/handle.js kernel/modules.js primitives/index.js shell/frame.js
       features/conversation/index.js features/plugins/index.js locales/en.js].each { |path| assert_includes tree, path }
    assert_empty tree.grep(%r{\Amodules/}), "modules/ is the daemon's mount prefix for extension modules"
    assert_empty tree.grep(%r{\Aassets/}), "nothing here is fingerprinted, so nothing may claim the immutable prefix"
    assert_empty tree.grep(/telegram/i), "the shell carries no plugin-specific interface"

    document = File.read(File.join(root, "index.html"))
    assert_includes document, '<script type="module" src="/app.js">'
    %w[tokens base icons primitives shell conversation panels].each do |sheet|
      assert_includes document, %(<link rel="stylesheet" href="/styles/#{sheet}.css">)
      assert_includes tree, "styles/#{sheet}.css"
    end
    refute_match(/<script(?![^>]*\bsrc=)/, document, "an inline script would be blocked by the daemon's CSP")
  end

  def test_the_package_advertises_the_daemon_extension
    spec = Gem::Specification.load(File.join(ROOT, "rho-webui.gemspec"))
    assert_equal "rho/webui", spec.metadata.fetch("rho_extensions")
    assert_equal "rho-extension.json", spec.metadata.fetch("rho_extension_manifest")
    assert_equal ["rho"], spec.runtime_dependencies.map(&:name)
    assert_empty spec.executables
    assert_empty spec.extensions
    shipped = spec.files.grep(%r{\Awebui/})
    on_disk = Dir.glob("webui/**/*", base: ROOT).select { |path| File.file?(File.join(ROOT, path)) }
    assert_equal on_disk.sort, shipped.sort
  end
end
