module Rho
  # Static files registered by a WebUI extension or an explicit root, plus the
  # browser modules of running extensions beneath the page's reserved
  # `modules/` prefix: no page served means no module served either.
  #
  # It is a plain single-page app, mounted same-origin so it can talk to the
  # control endpoints without CORS.
  #
  # The document is public and contains no credential. OAuthLogin exchanges
  # the browser's own Nexus authorization for its separate local session.
  # The per-boot operator bearer stays in the private announcement file.
  #
  # So this class serves files and nothing else, which is also what lets a
  # dev server serve the same build: there is no marker to honour and no
  # rewrite to reproduce.
  class StaticFiles
    Asset = Data.define(:body, :content_type, :cache_control)

    CONTENT_TYPES = {
      ".html" => "text/html; charset=utf-8",
      ".js" => "text/javascript; charset=utf-8",
      ".mjs" => "text/javascript; charset=utf-8",
      ".css" => "text/css; charset=utf-8",
      ".json" => "application/json",
      ".map" => "application/json",
      ".webmanifest" => "application/manifest+json",
      ".svg" => "image/svg+xml",
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".webp" => "image/webp",
      ".avif" => "image/avif",
      ".woff" => "font/woff",
      ".woff2" => "font/woff2",
      ".wasm" => "application/wasm",
      ".txt" => "text/plain; charset=utf-8",
      ".ico" => "image/x-icon",
    }.freeze
    DEFAULT_CONTENT_TYPE = "application/octet-stream".freeze
    ASSET_CACHE = "public, max-age=31536000, immutable".freeze
    # BY PATH, NOT BY EXTENSION. A build's fingerprinted output lives under
    # `assets/`; a service worker or a manifest sits at the ROOT under its own
    # unchanging name, and a year of `immutable` on one of those is an install
    # nobody can correct.
    FINGERPRINTED_PREFIX = "assets/".freeze
    PLAIN_CACHE = "no-cache".freeze
    # Reserved in every page root for running extensions' browser modules.
    MODULES_PREFIX = "modules/".freeze
    def self.available?(root) = File.file?(File.join(root, "index.html"))

    def initialize(root:, mounts: {})
      # REALPATH, NOT EXPAND_PATH: `expand_path` resolves `..` textually and
      # leaves symlinks alone, so a link inside the bundle pointing anywhere
      # on the disk passed the containment check and was served.
      @root = File.realpath(File.expand_path(root))
      # `prefix => root`; each root is already its registration's realpath.
      @mounts = mounts
    end

    def resolve(path)
      relative = path.delete_prefix("/")
      relative.start_with?(MODULES_PREFIX) ? mounted(relative) : page(relative)
    end

    private

      # The prefix is reserved for module mounts. A path under it that no
      # running extension serves, including a stale URL after that extension
      # stopped, is a 404 and never the page: a module has no index and no
      # deep links.
      def mounted(relative)
        prefix, root = @mounts.find { |candidate, _root| relative.start_with?(candidate) }
        file = prefix && safe_path(root, relative.delete_prefix(prefix))
        if file && File.file?(file)
          Asset.new(body: File.binread(file), content_type: content_type(file), cache_control: PLAIN_CACHE)
        end
      end

      # Missing assets must return 404 instead of an HTML document. Only a
      # path that could be a ROUTE — no extension, or `.html` with nothing on
      # disk — is a deep link the single-page app should answer.
      def page(relative)
        relative = "index.html" if relative.empty?
        file = safe_path(@root, relative)

        # A path that failed containment is not a deep link, whatever it looks
        # like: `/assets/../../etc/passwd` reads as route-shaped and is an
        # attempt to leave the bundle. It gets nothing rather than the page.
        return nil if file.nil?
        return index if File.file?(file) && File.extname(file) == ".html"
        return Asset.new(body: File.binread(file), content_type: content_type(file),
          cache_control: cache_control(relative)) if File.file?(file)

        deep_link?(relative) ? index : nil
      end

      # A served path is untrusted input. Resolving it and checking that the
      # result is still inside its root is what stops `../` from reading the
      # credential vault two directories up — for the page and every mount.
      def safe_path(root, relative)
        candidate = File.expand_path(File.join(root, relative))
        candidate = File.realpath(candidate) if File.exist?(candidate)
        return nil unless candidate == root || candidate.start_with?("#{root}#{File::SEPARATOR}")

        candidate
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENAMETOOLONG
        nil
      end

      # A path a router could own: no extension at all (`/workspaces/<id>`),
      # an `.html` name with no file behind it, or a dotted last segment that
      # names no asset type (`/plugins/rho.webui` — a plugin id). Anything
      # that looks like an asset — `.js`, `.css`, `.map` — is a 404 when it is
      # missing.
      def deep_link?(relative)
        extension = File.extname(relative)
        extension == ".html" || !CONTENT_TYPES.key?(extension)
      end

      def cache_control(relative)
        relative.start_with?(FINGERPRINTED_PREFIX) ? ASSET_CACHE : PLAIN_CACHE
      end

      def index
        # BINREAD, AND SAY WHAT IT IS: this machine has no LANG, so
        # `default_external` is US-ASCII and a UTF-8 document read by name
        # comes back invalid — bytes that still serve correctly but break
        # every assertion made about the document.
        Asset.new(
          body: File.binread(File.join(@root, "index.html")).force_encoding(Encoding::UTF_8),
          content_type: CONTENT_TYPES.fetch(".html"),
          cache_control: PLAIN_CACHE
        )
      end

      def content_type(file) = CONTENT_TYPES.fetch(File.extname(file), DEFAULT_CONTENT_TYPE)
  end
end
