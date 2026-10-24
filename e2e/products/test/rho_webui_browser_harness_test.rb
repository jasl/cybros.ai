require "test_helper"
require "minitest/mock"
require "support/rho_daemon"
require "support/rho_webui_browser"

class RhoWebuiBrowserHarnessTest < Minitest::Test
  include E2E::RhoWebuiBrowser

  def setup
    @root = Dir.mktmpdir("rho-menu-harness")
    File.write(File.join(@root, "index.html"), <<~HTML)
      <header class="conversation__header"><button>Conversation actions</button></header>
      <script>
        document.querySelector('button').onclick = () => {
          const menu = document.createElement('div');
          menu.setAttribute('role', 'menu');
          menu.innerHTML = '<button role="menuitem">Rename</button><button role="menuitem">Restore</button>';
          document.body.append(menu);
        };
        document.onkeydown = event => {
          if (event.key === 'Escape') document.querySelector('[role="menu"]').remove();
        };
      </script>
    HTML
    @browser = E2E::BrowserActor.new("file://#{@root}/")
    @browser.visit("index.html")
    @page = @browser.page
  end

  def teardown
    @browser&.close
    FileUtils.remove_entry(@root)
  end

  def test_menu_labels_are_read_together_when_an_async_refresh_replaces_the_items
    query = @page.method(:all)
    refreshed = false
    @page.stub(:all, lambda { |*args, **options|
      nodes = query.call(*args, **options)
      unless refreshed
        refreshed = true
        # Replace the nodes after Selenium finds them but before it reads
        # their text, as the late memory-review response can do.
        @page.execute_script("const menu = document.querySelector('[role=menu]'); menu.replaceChildren(...[...menu.children].map(node => node.cloneNode(true)))")
      end
      nodes
    }) do
      assert_equal %w[Rename Restore], menu_items("Conversation actions")
    end
    assert refreshed
  end
end
