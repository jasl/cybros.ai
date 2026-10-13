require "test_helper"
require "net/http"

# The public page carries no credential. Nexus OAuth gives the initiating
# browser its own local session after authorization; the operator's private
# announcement bearer never appears in the static document.
class WebuiTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-webui")
    @bundle = File.join(@root, "bundle")
    FileUtils.mkdir_p(File.join(@bundle, "assets"))
    File.write(File.join(@bundle, "index.html"), <<~HTML)
      <!doctype html><html><head><title>rho</title></head>
      <body><div id="root"></div><!--rho:bootstrap--></body></html>
    HTML
    File.write(File.join(@bundle, "assets", "app.js"), "export const hello = 1\n")
    @daemons = []
    @servers = []
  end

  def teardown
    @daemons.each { |daemon| daemon.stop if daemon.running? }
    @servers.each(&:stop)
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def boot
    daemon = Rho::Daemon.boot(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(@root, "home")),
      webui_root: @bundle
    )
    @daemons << daemon
    daemon
  end

  def get(daemon, path, host: nil)
    uri = URI.join(daemon.endpoint, path)
    request = Net::HTTP::Get.new(uri)
    request["Host"] = host if host
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  # A running extension's browser files, mounted where the daemon mounts them.
  def browser_module
    root = File.join(@root, "module")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "index.js"), "export function register(ui) {}\n")
    File.write(File.join(root, "setup.js"), "export const setup = 1\n")
    Rho::Extensions::WebuiModule.new(extension: "test.module", root: File.realpath(root))
  end

  # The page's own server with that module mounted, as the daemon builds it.
  def serve(mod)
    server = Rho::ControlServer.new(bind: "127.0.0.1", port: 0, routes: {},
      static_root: Rho::StaticFiles.new(root: @bundle, mounts: { mod.path => mod.root })).run
    @servers << server
    server
  end

  def fetch(server, path, verb: Net::HTTP::Get)
    Net::HTTP.start("127.0.0.1", server.port) { |http| http.request(verb.new(path)) }
  end

  def test_the_daemon_serves_its_own_page
    response = get(boot, "/")

    assert_equal "200", response.code
    assert_includes response["Content-Type"], "text/html"
    assert_includes response.body, %(<div id="root">)
  end

  # THE REGRESSION TEST FOR THE WHOLE CHANGE. `GET /` is unauthenticated by
  # necessity, so anything in the document is public to every process that can
  # open the port.
  def test_the_document_carries_no_credential
    daemon = boot
    body = get(daemon, "/").body

    refute_includes body, daemon.bearer
    refute_includes body, Rho::Daemon::LOCAL_BEARER_PREFIX
    refute_includes body, "__RHO__"
    assert_includes body, %(<div id="root">), "and it is still the page"
  end

  # A build that never heard of rho serves normally: there is no marker to
  # honour, which is what lets a dev server serve the same bytes.
  def test_a_build_with_no_marker_is_served_as_it_is
    File.write(File.join(@bundle, "index.html"), "<!doctype html><p>hello</p>")

    response = get(boot, "/")
    assert_equal "200", response.code
    assert_includes response.body, "<p>hello</p>"
  end

  # The document holds nothing to keep out of caches now, but it is still the
  # file that changes on every build.
  def test_the_document_is_revalidated_while_its_assets_are_immutable
    daemon = boot

    assert_equal "no-cache", get(daemon, "/")["Cache-Control"]
    assert_includes get(daemon, "/assets/app.js")["Cache-Control"], "immutable"
    assert_includes get(daemon, "/assets/app.js")["Content-Type"], "text/javascript"
  end

  # THE defence. Without it a loopback bind is not enough: an attacker points
  # their own hostname at 127.0.0.1, the browser calls that same-origin, and
  # their script reads our response — bearer included.
  def test_a_request_arriving_under_a_foreign_hostname_is_refused
    daemon = boot

    ["evil.example", "rebind.attacker.test", "nexus.example"].each do |host|
      response = get(daemon, "/", host: host)
      assert_equal "421", response.code, "#{host} must not be served"
      refute_includes response.body, daemon.bearer
    end
  end

  def test_loopback_names_are_served
    daemon = boot
    port = URI.parse(daemon.endpoint).port

    ["127.0.0.1:#{port}", "localhost:#{port}", "[::1]:#{port}"].each do |host|
      assert_equal "200", get(daemon, "/", host: host).code, "#{host} is loopback"
    end
  end

  # The control endpoints are behind the same check, so a rebound page cannot
  # start a ceremony either — even though it never got the bearer.
  def test_the_control_endpoints_are_behind_the_same_check
    daemon = boot
    uri = URI.join(daemon.endpoint, "/status")
    request = Net::HTTP::Get.new(uri)
    request["Host"] = "evil.example"
    request["Authorization"] = "Bearer #{daemon.bearer}"

    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    assert_equal "421", response.code
  end

  # A served path is untrusted input, and the credential vault lives two
  # directories up from the bundle. A path that failed containment is not a
  # deep link however route-shaped it reads: it gets nothing, because the page
  # it would otherwise get carries the per-boot bearer.
  def test_a_path_that_tries_to_leave_the_bundle_never_reads_outside_it
    daemon = boot

    ["/../home/installations", "/assets/../../etc/passwd", "/%2e%2e/%2e%2e/etc/passwd"].each do |path|
      response = get(daemon, path)
      # A client normalises `..` before it reaches us, so what arrives is an
      # ordinary route-shaped miss and the page is the right answer. What may
      # never happen is a byte from outside the bundle.
      refute_includes response.body.to_s, "root:", "#{path} read outside the bundle"
      assert_includes ["200", "404"], response.code, path
    end
  end

  # THE CONTAINMENT ITSELF, below HTTP: a client normalises `..` away, so the
  # only way to test the check is to hand the resolver the raw path.
  def test_the_resolver_refuses_a_path_that_leaves_the_bundle
    webui = Rho::StaticFiles.new(root: @bundle)

    assert_nil webui.resolve("/../../etc/passwd")
    assert_nil webui.resolve("/assets/../../../etc/passwd")
  end

  # `expand_path` resolves `..` textually and leaves symlinks alone, so a link
  # inside the bundle pointing anywhere on the disk passed the check and was
  # served — unauthenticated.
  def test_the_resolver_refuses_a_symlink_that_points_out_of_the_bundle
    secret = File.join(@root, "outside.txt")
    File.write(secret, "not for the browser")
    File.symlink(secret, File.join(@bundle, "assets", "escape.js"))

    assert_nil Rho::StaticFiles.new(root: @bundle).resolve("/assets/escape.js")
  end

  # A deep link typed by hand is an ordinary way to arrive at a single-page
  # app — including one whose last segment is a dotted plugin id.
  def test_an_unknown_path_falls_back_to_the_page
    daemon = boot
    ["/connect", "/workspaces/w-1/conversations/c-1", "/plugins/rho.ingress_telegram", "/panels/t3"].each do |path|
      response = get(daemon, path)

      assert_equal "200", response.code, path
      assert_includes response.body, %(<div id="root">), path
    end
  end

  # A MISS IS A MISS. Falling back to the index for everything meant
  # `/nonexistent.js` answered 200 text/html with the bearer inside it — a
  # credential served to any path a stranger cares to invent.
  def test_a_missing_asset_is_a_404_rather_than_the_page
    daemon = boot

    ["/nope.js", "/assets/gone-abc123.js", "/style.css", "/app.js.map"].each do |path|
      response = get(daemon, path)
      assert_equal "404", response.code, "#{path} must not be answered with the page"
      refute_includes response.body.to_s, "__RHO__", "#{path} must not carry the bearer"
    end
  end

  # Every served byte says do not guess what it is, and the document says do
  # not frame me: both are credential boundaries here, not lint.
  def test_the_mount_sends_the_headers_that_keep_the_document_from_being_reused
    response = get(boot, "/")

    assert_equal "nosniff", response["x-content-type-options"]
    assert_equal "DENY", response["x-frame-options"]
    assert_equal "no-referrer", response["referrer-policy"]
    # The page renders model output, which is downstream of tool results a
    # remote party influences. One rendering bug that executes script runs
    # against a surface whose every route runs shell commands.
    policy = response["content-security-policy"].to_s
    assert_includes policy, "script-src 'self'"
    assert_includes policy, "frame-ancestors 'none'"
    assert_includes policy, "object-src 'none'"
  end

  # A JSON answer renders nothing, so it carries no policy — but it still says
  # do not guess what it is.
  def test_a_json_answer_carries_no_policy_and_still_says_nosniff
    response = get(boot, "/healthz")

    assert_nil response["content-security-policy"]
    assert_equal "nosniff", response["x-content-type-options"]
  end

  # `immutable` is a promise about a fingerprinted name. A service worker or a
  # manifest sits at the root under its own unchanging name, and a year of it
  # is an install nobody can correct.
  def test_only_fingerprinted_assets_are_cached_forever
    daemon = boot
    File.write(File.join(@bundle, "sw.js"), "self.addEventListener('install', () => {})")
    FileUtils.mkdir_p(File.join(@bundle, "assets"))
    File.write(File.join(@bundle, "assets", "app-abc123.js"), "export default 1")

    assert_equal "no-cache", get(daemon, "/sw.js")["cache-control"]
    assert_includes get(daemon, "/assets/app-abc123.js")["cache-control"], "immutable"
  end

  # A build whose index lost the marker ships no bearer, and `String#sub`
  # would say nothing about it: a blank page, a 200, and no diagnosis.
  # `curl -I` is the whole reason HEAD is answered; it reported everything as
  # empty because dropping the body recomputed the length.
  def test_head_keeps_the_length_it_would_have_sent
    daemon = boot
    request = Net::HTTP::Head.new(URI.join(daemon.endpoint, "/"))
    uri = URI.join(daemon.endpoint, "/")
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }

    assert_equal "200", response.code
    assert_operator response["content-length"].to_i, :>, 0
  end

  # With no bundle the daemon still runs: a missing build must not cost it its
  # control surface.
  def test_a_daemon_without_a_bundle_still_serves_its_control_surface
    daemon = Rho::Daemon.boot(
      home: Rho::Home.resolve(base_url: "https://other.example", root: File.join(@root, "home2")),
      webui_root: File.join(@root, "absent")
    )
    @daemons << daemon

    assert_equal "200", get(daemon, "/healthz").code
    assert_equal "404", get(daemon, "/").code
  end

  # A module is plain browser code like the page's own, so it travels with the
  # same headers: revalidated, never sniffed, and a policy only on documents.
  def test_a_mounted_module_file_is_served_like_the_pages_own_scripts
    mod = browser_module
    File.write(File.join(mod.root, "page.html"), "<!doctype html><p>module page</p>")
    server = serve(mod)
    response = fetch(server, mod.entry)

    assert_equal "200", response.code
    assert_equal "export function register(ui) {}\n", response.body
    assert_equal "text/javascript; charset=utf-8", response["content-type"]
    assert_equal "no-cache", response["cache-control"]
    assert_equal "nosniff", response["x-content-type-options"]
    assert_nil response["content-security-policy"]
    assert_equal "export const setup = 1\n", fetch(server, "/#{mod.path}setup.js").body
    assert_includes fetch(server, "/#{mod.path}page.html")["content-security-policy"], "script-src 'self'"
  end

  # A module has no index and no deep links: a miss under its mount is a miss,
  # never the page that carries the login flow.
  def test_a_missing_module_file_and_the_mount_root_are_404_and_never_the_page
    mod = browser_module
    server = serve(mod)

    ["/#{mod.path}missing.js", "/#{mod.path}", "/#{mod.path}settings/telegram"].each do |path|
      response = fetch(server, path)
      assert_equal "404", response.code, path
      refute_includes response.body.to_s, %(<div id="root">), path
    end
  end

  # The prefix is reserved: a stale URL from an extension that stopped, or one
  # that never ran, is a 404 even when it reads like a route.
  def test_a_module_url_no_running_extension_serves_is_404
    server = serve(browser_module)

    ["/modules/gone/abcdef012345/", "/modules/gone/abcdef012345/index.js", "/modules/x"].each do |path|
      response = fetch(server, path)
      assert_equal "404", response.code, path
      refute_includes response.body.to_s, %(<div id="root">), path
    end
  end

  # One containment check for the page and every mount: a client normalises
  # `..` away, so the resolver is handed the raw path.
  def test_the_resolver_keeps_a_mount_inside_its_own_directory
    mod = browser_module
    secret = File.join(@root, "outside.js")
    File.write(secret, "not for the browser")
    File.symlink(secret, File.join(mod.root, "escape.js"))
    webui = Rho::StaticFiles.new(root: @bundle, mounts: { mod.path => mod.root })

    assert_nil webui.resolve("/#{mod.path}../../../etc/passwd")
    assert_nil webui.resolve("/#{mod.path}../outside.js")
    assert_nil webui.resolve("/#{mod.path}escape.js")
    assert_equal "export function register(ui) {}\n", webui.resolve(mod.entry).body
  end

  def test_head_of_a_module_file_keeps_its_length
    mod = browser_module
    response = fetch(serve(mod), mod.entry, verb: Net::HTTP::Head)

    assert_equal "200", response.code
    assert_equal "export function register(ui) {}\n".bytesize, response["content-length"].to_i
  end
end
