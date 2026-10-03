require "digest"

module Rho
  # THE BOOT ACCELERATOR, wired the way Homebrew
  # wires bootsnap: a load-path index and an iseq cache in a per-user cache
  # directory, keyed so that a Ruby upgrade, a gem-set change or a moved
  # code root lands in a fresh directory instead of doubling a stale one
  # (iseq entries are keyed by full path and bootsnap never cleans).
  #
  # Runs in `exe/rho` after the encoding lines and before `require "thor"`,
  # so everything after benefits. NEVER A BOOT DEPENDENCY: the gem absent,
  # the cache unwritable, an internal error — every case falls back to
  # uncached loading and says one line on stderr at most.
  #
  # Where the cache lives: `$RHO_BOOTSNAP_CACHE_DIR` when set (the image
  # points it at the image layer; the wrapper `bin/rho` sets it to the
  # home's `cache/bootsnap` so a checkout and an install agree), else
  # `$RHO_HOME/cache/bootsnap`. The whole chain is created 0700: RHO_HOME's
  # discipline, and a root-owned cache under a user's home is the failure
  # that hurt Homebrew (issue 19904) — a cache the euid cannot write is
  # simply not used.
  module Boot
    OFF_SWITCH = "RHO_NO_BOOTSNAP".freeze
    CACHE_DIR_ENV = "RHO_BOOTSNAP_CACHE_DIR".freeze
    HOME_ENV = "RHO_HOME".freeze
    DEFAULT_HOME = "~/.rho".freeze
    PRIVATE_MODE = 0o700
    KEY_LENGTH = 24

    module_function

    # The one call `exe/rho` makes. Answers the cache directory it set up,
    # or nil when bootsnap is off, absent or unusable.
    def setup!(env = ENV, root: code_root)
      return nil if off?(env)

      directory = cache_directory(env, root: root)
      return nil unless prepare(directory)

      require "bootsnap"
      Bootsnap.setup(
        cache_dir: directory,
        development_mode: development?(env, root: root),
        load_path_cache: true,
        compile_cache_iseq: !coverage_running?,
        compile_cache_yaml: false
      )
      directory
    rescue LoadError
      nil
    rescue StandardError => error
      warn "rho: bootsnap disabled: #{error.class}: #{error.message}"
      nil
    end

    def off?(env) = !env[OFF_SWITCH].to_s.empty?

    # `<cache root>/<key>`: the root from the environment or the home.
    def cache_directory(env, root: code_root)
      File.join(cache_root(env), key(root: root))
    end

    def cache_root(env)
      configured = env[CACHE_DIR_ENV].to_s
      return File.expand_path(configured) unless configured.strip.empty?

      home = env[HOME_ENV].to_s
      home = DEFAULT_HOME if home.strip.empty?
      File.join(File.expand_path(home), "cache", "bootsnap")
    end

    # SHA256(RUBY_DESCRIPTION ∥ arch ∥ resolved code root ∥ SHA256(lock))[0, 24]:
    # a Ruby patch, a moved prefix and a changed gem set each move to a
    # fresh directory.
    def key(root: code_root)
      parts = [RUBY_DESCRIPTION, RbConfig::CONFIG["arch"], root, lock_digest(root)]
      Digest::SHA256.hexdigest(parts.join("\n"))[0, KEY_LENGTH]
    end

    # The rho checkout or installed tree, resolved.
    def code_root
      File.realpath(File.expand_path("../..", __dir__))
    end

    # An installed prefix's tree is immutable, so its files are never
    # re-checked; a checkout's are (a developer edits them).
    def development?(env, root: code_root)
      prefix = env["RHO_PREFIX"].to_s
      return true if prefix.strip.empty?

      !root.start_with?("#{File.realpath(File.expand_path(prefix))}/")
    rescue Errno::ENOENT
      true
    end

    def lock_digest(root)
      lock = File.join(root, "Gemfile.lock")
      File.file?(lock) ? Digest::SHA256.file(lock).hexdigest : "no-lock"
    end

    # Ruby refuses `to_binary` while Coverage runs.
    def coverage_running?
      return false unless defined?(::Coverage) && ::Coverage.respond_to?(:running?)

      ::Coverage.running? ? true : false
    end

    # The chain, 0700 at every level this process creates (an explicit
    # chmod: a narrowing umask would turn the requested mode into 0500);
    # false when the result is not a directory the euid can write.
    def prepare(directory)
      missing = []
      cursor = directory
      until File.directory?(cursor)
        missing.unshift(cursor)
        parent = File.dirname(cursor)
        return false if parent == cursor

        cursor = parent
      end
      missing.each do |path|
        Dir.mkdir(path, PRIVATE_MODE)
        File.chmod(PRIVATE_MODE, path)
      end
      File.writable?(directory)
    rescue SystemCallError
      false
    end
  end
end
