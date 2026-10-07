module Rho
  # Static files registered by a WebUI extension or an explicit root.
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
    def self.available?(root) = File.file?(File.join(root, "index.html"))

    def initialize(root:)
      # REALPATH, NOT EXPAND_PATH: `expand_path` resolves `..` textually and
      # leaves symlinks alone, so a link inside the bundle pointing anywhere
      # on the disk passed the containment check and was served.
      @root = File.realpath(File.expand_path(root))
    end

    # Missing assets must return 404 instead of an HTML document. Only a
    # path that could be a ROUTE — no extension, or `.html` with nothing on
    # disk — is a deep link the single-page app should answer.
    def resolve(path)
      relative = path.delete_prefix("/")
      relative = "index.html" if relative.empty?
      file = safe_path(relative)

      # A path that failed containment is not a deep link, whatever it looks
      # like: `/assets/../../etc/passwd` reads as route-shaped and is an
      # attempt to leave the bundle. It gets nothing rather than the page.
      return nil if file.nil?
      return index if File.file?(file) && File.extname(file) == ".html"
      return Asset.new(body: File.binread(file), content_type: content_type(file),
        cache_control: cache_control(relative)) if File.file?(file)

      deep_link?(relative) ? index : nil
    end

    private

      # A served path is untrusted input. Resolving it and checking that the
      # result is still inside the bundle is what stops `../` from reading the
      # credential vault two directories up.
      def safe_path(relative)
        candidate = File.expand_path(File.join(@root, relative))
        candidate = File.realpath(candidate) if File.exist?(candidate)
        return nil unless candidate == @root || candidate.start_with?("#{@root}#{File::SEPARATOR}")

        candidate
      rescue Errno::ENOENT, Errno::ELOOP, Errno::ENAMETOOLONG
        nil
      end

      # A path a router could own: no extension at all (`/runs/al-1`), or an
      # `.html` name with no file behind it. Anything that looks like an asset
      # — `.js`, `.css`, `.map` — is a 404 when it is missing.
      def deep_link?(relative)
        extension = File.extname(relative)
        extension.empty? || extension == ".html"
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
