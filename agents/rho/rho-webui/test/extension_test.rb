require "test_helper"

class ExtensionTest < Minitest::Test
  include WebuiTest

  def test_registration_points_to_a_complete_browser_bundle
    root = registered_root
    assert_equal File.join(ROOT, "webui"), root
    assert_equal %w[api.js console.css console.js controls.js index.html lifecycle.js markdown.js scheduled_jobs.js views.js], Dir.children(root).sort

    document = File.read(File.join(root, "index.html"))
    assert_includes document, '<script type="module" src="/console.js">'
    assert_includes document, '<link rel="stylesheet" href="/console.css">'
  end

  def test_the_package_advertises_the_daemon_extension
    spec = Gem::Specification.load(File.join(ROOT, "rho-webui.gemspec"))
    assert_equal "rho/webui", spec.metadata.fetch("rho_extensions")
    assert_equal ["rho"], spec.runtime_dependencies.map(&:name)
    assert_empty spec.executables
    assert_empty spec.extensions
  end
end
