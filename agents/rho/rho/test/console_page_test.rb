require "test_helper"
require "net/http"

# The rho-webui plugin page, served by the daemon that loads it. Not a render
# test — a test that the bundle is reachable, that every asset it names
# resolves, and that it carries nothing it must not.
class ConsolePageTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-console-page")
    @daemon = Rho::Daemon.boot(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "home"))
    )
  end

  def teardown
    @daemon.stop if @daemon&.running?
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def get(path)
    uri = URI.join(@daemon.endpoint, path)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(Net::HTTP::Get.new(uri)) }
  end

  def test_the_default_plugin_ships_a_page_and_the_daemon_serves_it
    assert_predicate @daemon, :page?, "the default plugin bundle must be found without configuration"

    response = get("/")
    assert_equal "200", response.code
    assert_includes response["Content-Type"], "text/html"
    assert_includes response.body, %(<div id="root")
  end

  # A page whose script 404s is a blank screen with a 200 on it.
  def test_every_asset_the_document_names_resolves
    body = get("/").body
    referenced = body.scan(/(?:src|href)="(\/[^"]+)"/).flatten
    refute_empty referenced, "the document must actually name its assets"

    referenced.each do |path|
      response = get(path)
      assert_equal "200", response.code, "#{path} is named by index.html and does not resolve"
      refute_empty response.body.to_s, path
    end
  end

  # The modules import each other by relative path; those are assets too, and
  # nothing in the document names them.
  def test_the_modules_the_entry_imports_resolve_too
    pending = ["console.js"]
    visited = []
    until pending.empty?
      name = pending.shift
      next if visited.include?(name)

      response = get("/#{name}")
      assert_equal "200", response.code, "#{name} is imported and does not resolve"
      assert_includes response["Content-Type"], "text/javascript"
      visited << name
      pending.concat(response.body.scan(/from\s+"\.\/([\w.-]+)"/).flatten)
    end
    assert_operator visited.length, :>, 1, "the entry must import its modules"
  end

  # `script-src 'self'` is what makes the CSP affordable, and it is affordable
  # only because nothing in the document is inline.
  def test_the_document_carries_no_inline_script
    body = get("/").body

    refute_match(/<script(?![^>]*\bsrc=)/, body, "an inline script would be blocked by our own CSP")
    refute_includes body, "__RHO__"
    refute_includes body, Rho::Daemon::LOCAL_BEARER_PREFIX
  end

  # THE COMPOSER HAS ONE VERB. Whatever the person types is said to the
  # host through `/say`; the daemon picks the door by the host it follows,
  # and the kernel picks the moment.
  def test_the_page_says_everything_through_the_one_door
    console = get("/console.js").body

    assert_includes console, "/say"
  end

  # THE THREAD's row: a round's `calls` is `{count, items}` and its
  # `branches` a list of call keys — the page reads both by name.
  def test_the_page_reads_the_threads_row_shape
    views = get("/views.js").body

    assert_includes views, "round.calls"
    assert_includes views, "fan.items"
    assert_includes views, "fan.count"
    assert_includes views, "round.branches"
  end

  # Every verb the console offers must be a route the daemon serves; a button
  # wired to a path that 404s is a dead control that looks alive. And every
  # one is the core's or a DEFAULT extension's: a page that leaned on an
  # operator's extension would be dead on every other machine.
  def test_every_path_the_page_posts_to_is_a_route_this_daemon_answers
    console = get("/console.js").body
    posted = console.scan(%r{(?:call|act)\(\s*"(/[a-z/]+)[?"]}).flatten.uniq
    refute_empty posted

    owners = @daemon.routes.entries.group_by(&:path).transform_values { |routes| routes.map(&:extension).uniq }
    shipped = ["rho", *Rho::Extensions::DEFAULT_EXTENSIONS.map { |extension| extension::NAME }]
    posted.each do |path|
      assert owners.key?(path), "the page posts to #{path} and no route claims it"
      owners.fetch(path).each do |owner|
        assert_includes shipped, owner, "#{path} is served by #{owner}, which rho does not ship"
      end
    end
    # Routes that reached the page from an extension, so the split is real.
    assert_equal ["rho.ops"], owners.fetch("/runs")
    assert_equal ["rho.ops"], owners.fetch("/files/bytes")
  end

  # Only a fingerprinted name earns a year, and nothing here has one.
  def test_no_shipped_asset_claims_to_be_immutable
    ["/console.js", "/console.css", "/api.js", "/views.js", "/markdown.js", "/controls.js"].each do |path|
      refute_includes get(path)["Cache-Control"].to_s, "immutable", path
    end
  end
end
