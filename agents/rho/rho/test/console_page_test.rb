require "test_helper"
require "net/http"

# The rho-webui plugin page, served by the daemon that loads it. Not a render
# test — a test that the bundle is reachable, that every asset it names
# resolves, and that it carries nothing it must not.
class ConsolePageTest < Minitest::Test
  IMPORT = /^\s*(?:import|export)\b[^"'\n]*?from\s+["'](\.{1,2}\/[^"']+)["']|^\s*import\s+["'](\.{1,2}\/[^"']+)["']/

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

  # Every module the entry reaches through static imports, by served path.
  def module_graph
    @module_graph ||= begin
      pending = ["/app.js"]
      visited = {}
      until pending.empty?
        path = pending.shift
        next if visited.key?(path)

        response = get(path)
        assert_equal "200", response.code, "#{path} is imported and does not resolve"
        assert_includes response["Content-Type"], "text/javascript", path
        visited[path] = response.body
        response.body.scan(IMPORT).flatten.compact.each do |specifier|
          pending << File.expand_path(specifier, File.dirname(path))
        end
      end
      visited
    end
  end

  def test_the_default_plugin_ships_a_page_and_the_daemon_serves_it
    assert_predicate @daemon, :page?, "the default plugin bundle must be found without configuration"

    response = get("/")
    assert_equal "200", response.code
    assert_includes response["Content-Type"], "text/html"
    assert_includes response.body, %(<div id="root")
    assert_includes response.body, %(<div id="boot")
  end

  # A page whose script 404s is a blank screen with a 200 on it.
  def test_every_asset_the_document_names_resolves
    body = get("/").body
    referenced = body.scan(/(?:src|href)="(\/[^"]+)"/).flatten
    refute_empty referenced, "the document must actually name its assets"
    assert_includes referenced, "/app.js"
    assert_equal 7, referenced.grep(%r{\A/styles/.*\.css\z}).length

    referenced.each do |path|
      response = get(path)
      assert_equal "200", response.code, "#{path} is named by index.html and does not resolve"
      refute_empty response.body.to_s, path
    end
  end

  # The modules import each other by relative path across kernel/, primitives/,
  # shell/ and features/; those are assets too, and nothing in the document
  # names them.
  def test_the_modules_the_entry_imports_resolve_too
    graph = module_graph
    assert_operator graph.length, :>, 20, "the entry must reach its layers"
    %w[/kernel/slots.js /kernel/outlets.js /kernel/modules.js /kernel/handle.js /primitives/index.js /shell/frame.js /shell/dock.js
       /features/conversation/index.js /features/plugins/index.js /features/settings/index.js /locales/en.js].each do |path|
      assert graph.key?(path), "#{path} must be reachable from app.js"
    end
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
    assert module_graph.values.any? { |source| source.include?('"/say"') }, "no shipped module posts to /say"
  end

  # THE THREAD's row: a round's `calls` is `{count, items}` and its
  # `branches` a list of call keys — the page reads all of them by name.
  def test_the_page_reads_the_threads_row_shape
    sources = module_graph.values.join("\n")
    %w[round.calls fan.items fan.count round.branches].each do |read|
      assert_includes sources, read
    end
  end

  # Every verb the page offers must be a route the daemon serves; a button
  # wired to a path that 404s is a dead control that looks alive. And every
  # one is the core's or a DEFAULT extension's: a page that leaned on an
  # operator's extension would be dead on every other machine. Plugin UI
  # arrives through modules the plugin itself ships, so the shell names no
  # plugin route.
  def test_every_path_the_page_posts_to_is_a_route_this_daemon_answers
    sources = module_graph
    literal = sources.values.flat_map { |source| source.scan(/\bcall\(\s*"(\/[a-z_\/]+)[?"]/).flatten }.uniq
    prefixes = sources.values.flat_map { |source| source.scan(/\bcall\(\s*`(\/[a-z_\/]+)\$\{/).flatten }.uniq
    refute_empty literal

    owners = @daemon.routes.entries.group_by(&:path).transform_values { |routes| routes.map(&:extension).uniq }
    shipped = ["rho", *Rho::Extensions::DEFAULT_EXTENSIONS.map { |extension| extension::NAME }]
    literal.each do |path|
      assert owners.key?(path), "the page calls #{path} and no route claims it"
      owners.fetch(path).each do |owner|
        assert_includes shipped, owner, "#{path} is served by #{owner}, which rho does not ship"
      end
    end
    prefixes.each do |prefix|
      assert owners.keys.any? { |path| path.start_with?(prefix) }, "the page builds paths under #{prefix} and no route lives there"
    end
    sources.each do |path, source|
      refute_includes source, "/telegram", "#{path} knows a plugin route; that interface belongs to the plugin's module"
    end
    # Routes that reached the page from an extension, so the split is real.
    assert_equal ["rho.ops"], owners.fetch("/runs")
    assert_equal ["rho.ops"], owners.fetch("/files/bytes")
  end

  # Only a fingerprinted name earns a year, and nothing here has one.
  def test_no_shipped_asset_claims_to_be_immutable
    paths = module_graph.keys + get("/").body.scan(/href="(\/styles\/[^"]+)"/).flatten
    paths.each do |path|
      refute_includes get(path)["Cache-Control"].to_s, "immutable", path
    end
  end
end
