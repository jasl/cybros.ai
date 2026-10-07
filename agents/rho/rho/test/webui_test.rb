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
  end

  def teardown
    @daemons.each { |daemon| daemon.stop if daemon.running? }
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

  # A deep link typed by hand is an ordinary way to arrive at a single-page app.
  def test_an_unknown_path_falls_back_to_the_page
    response = get(boot, "/connect")

    assert_equal "200", response.code
    assert_includes response.body, %(<div id="root">)
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
end
