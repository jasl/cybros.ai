require "cybros_agent"
require "fileutils"
require "json"
require "securerandom"
require "uri"

module Rho
  # Where rho keeps things. rho owns the paths and the policy;
  # the gem owns the format of what lands in them.
  #
  # **One RHO_HOME is one Nexus.** There is no per-Nexus layer inside the tree:
  # switching environments is switching RHO_HOME, which is already how it is
  # done, and the layer only ever bought the ability to hold two connections in
  # one directory while making every path a digest deeper. What survives of it
  # is a single recorded fact, `nexus.json`, used as a **binding guard**: a home
  # bound to one address refuses a different one rather than quietly growing a
  # second credential tree beside the first.
  #
  # Agent identities live under `users/`, keyed by the public id learned from
  # the member plane after a successful ceremony.
  #
  # The root holds durable things; `tmp/` and `log/` hold the rest:
  #
  #   `tmp/` is what a fresh boot rebuilds — the boot lock and the announcement
  #   naming this daemon's endpoint and per-boot bearer. Deleting it costs
  #   nothing but a restart.
  #
  #   `log/` is the daemon's only recoverable scene. It is not state, and
  #   losing it loses only history, but it must not sit among files a person
  #   might reasonably delete to reclaim space.
  #
  #   **Staging does not move to `tmp/`.** A connection in flight is
  #   short-lived but not disposable: deleting it between the mint and the
  #   install costs a human a browser ceremony and orphans a connection at
  #   Nexus. It sits at the root beside `users/` because that
  #   is what it is — the connection that has not landed yet.
  #
  # State and work are separate trees, and the dividing line is what it costs
  # to lose them:
  #
  #   The state root (`RHO_HOME`) holds what cannot be rebuilt — credential
  #   vaults, identity roots, staging, the binding, the instance id
  # (`instance.json`), and the MCP OAuth credentials
  #   (`mcp/credentials/<server>.json`, one 0600 file per server rho-mcp
  #   logged in to — a person's browser consent, which is what losing one
  #   costs). Losing any of it costs a human a fresh browser ceremony or
  #   breaks a durability promise.
  #
  #   The work root (`RHO_WORK_DIR`, by default `<RHO_HOME>/work`) holds what
  #   can be rebuilt or re-fetched — workspace checkouts and homes, conversation
  # artifacts, scratch, and `checkpoints/<digest>/`: the runner's
  #   shadow git store per root, PROJECT bytes (secrets included) captured
  #   before a loop's first write and pruned after `retention_days`; its loss
  #   is graceful (`checkpoint_unknown`, the fork made), and a backup of the
  #   state root must never carry it. It is the large, churny half: an
  #   operator may want it on a different volume, on faster disk, excluded
  #   from backups, or wiped between runs, and none of that should endanger a
  #   connection.
  #
  #   Open when the Task plane lands: any attempt WAL stays in the state root —
  #   losing it means re-running or dropping work, which is not a rebuild.
  #   Decide its final identity-relative path with its first writer.
  class Home
    DEFAULT_ROOT = "~/.rho".freeze
    # Where rho talks to when nobody says otherwise. A hosted product has one
    # address and it does not change, so asking for it on every command is
    # friction; development is the unstable case, and that is what the flag and
    # the environment variable are for.
    DEFAULT_NEXUS_URL = "https://cybros.ai".freeze
    BINDING_VERSION = 1
    INSTANCE_VERSION = 1
    # Eight lowercase hex characters (32 bits): a collision under one
    # steward negligible, the spelling shell-safe, never typed by a person.
    INSTANCE_ID = /\A[0-9a-f]{8}\z/
    DEFAULT_WORK_DIRECTORY = "work".freeze
    TMP_DIRECTORY = "tmp".freeze
    LOG_DIRECTORY = "log".freeze
    # The bootsnap cache (`Rho::Boot#cache_root`, which spells the name
    # itself: it runs before this file loads).
    CACHE_DIRECTORY = "cache".freeze
    PRIVATE_DIRECTORY_MODE = 0o700
    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze
    # A path segment is safe when it cannot leave the tree or confuse the
    # filesystem. Public identifiers are UUIDv7 today, but they arrive from the
    # wire, and a vault placed outside the home is not recoverable.
    SAFE_SEGMENT = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/

    attr_reader :root, :work_root, :base_url

    # An empty RHO_HOME is unset, not the current directory. `File.expand_path("")`
    # is the working directory, so honouring it literally would put the
    # credential vault wherever the process happened to start — a different
    # home per directory, each with its own boot lock — and narrow that
    # directory to 0700 on the way. `RHO_HOME= rho server`, an unset `ENV` line
    # in a Dockerfile, and `Environment=RHO_HOME=` in a unit file all produce it.
    def self.default_root
      configured(ENV["RHO_HOME"]) || DEFAULT_ROOT
    end

    # Defaults inside the state root, so a plain install stays one directory,
    # and moves independently when an operator wants it elsewhere.
    def self.default_work_root(root)
      configured(ENV["RHO_WORK_DIR"]) || File.join(root, DEFAULT_WORK_DIRECTORY)
    end

    def self.configured(value)
      value.nil? || value.strip.empty? ? nil : value
    end

    # The binding guard runs here rather than at `prepare`, so a mistyped
    # `--nexus-url` is refused before anything reads a vault or takes a lock.
    # It compares canonical forms: a trailing slash is not a different Nexus.
    def self.resolve(base_url:, root: default_root, work_root: nil)
      raise ConfigurationError, "#{root.inspect} is not a usable RHO_HOME" if root.to_s.strip.empty?

      root = File.expand_path(root)
      canonical = canonical_base_url(base_url)
      bound = bound_address(root: root)
      if bound && bound != canonical
        raise ConfigurationError,
          "#{root} is connected to #{bound}; it cannot also be #{canonical}. " \
          "Use a different RHO_HOME for a different Nexus."
      end

      work_root = configured(work_root) || default_work_root(root)
      new(base_url: canonical, root: root, work_root: File.expand_path(work_root))
    end

    # Which Nexus this home is bound to, or nil for a fresh one. Commands use
    # it to default to the obvious address instead of asking for a URL a
    # production install has had fixed since the day it was set up.
    def self.bound_address(root: default_root)
      document = Rho::StateFile.new(File.join(File.expand_path(root), "nexus.json")).read
      document.is_a?(Hash) ? document["base_url"] : nil
    rescue StateError
      nil
    end

    # Same address, same home — whatever the operator typed. A daemon
    # started with a trailing slash must take the same lock as one started
    # without it, or both run against one account at once.
    def self.canonical_base_url(value)
      uri = URI.parse(value.to_s)
      unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
        raise ConfigurationError, "#{value.inspect} is not an absolute http(s) URL"
      end

      scheme = uri.scheme.downcase
      canonical = +"#{scheme}://#{uri.host.downcase}"
      canonical << ":#{uri.port}" unless uri.port == DEFAULT_PORTS[scheme]
      canonical << uri.path.chomp("/")
      canonical
    rescue URI::InvalidURIError
      raise ConfigurationError, "#{value.inspect} is not a URL"
    end

    def initialize(base_url:, root:, work_root:)
      @base_url = base_url
      @root = root
      @work_root = work_root
    end

    def tmp_root = File.join(@root, TMP_DIRECTORY)
    def log_root = File.join(@root, LOG_DIRECTORY)
    def log_path = File.join(log_root, "rho.log")
    def cache_root = File.join(@root, CACHE_DIRECTORY)
    # The identity roots' and the runner roots' parents (`identity_root`,
    # `runner_identity_root`): the vaults live under them.
    def users_root = File.join(@root, "users")
    def runners_root = File.join(@root, "runners")
    # The person's standing rules for every root this home works on
    # (`Rho::Conventions`, which reads it by path).
    def conventions_path = File.join(@root, Conventions::HOME_FILENAME)

    # THE PROTECTED MEMBERS: every entry of this layout EXCEPT the work root — the config,
    # the binding, the instance, the pointers, the standing rules, the connections in
    # flight, the identity and runner vaults, the MCP and Telegram credentials, the adaptation rows, the
    # extension code, the caches, `tmp/` and `log/` — the files and directories a model
    # never writes, ENUMERATED so that the self-modification denies (`Rho.protected_roots`,
    # the guard's floor, the checkpoint store's exclusions) name each member and never the
    # home itself: the kernel's globs cannot carve a subtree out of a root, and the work
    # root (`work_root`, by default `<RHO_HOME>/work`) is the person's project area by
    # construction — the default environment root and the default checkpoint store sit under
    # it — so it is simply not in the list, wherever it is placed. A member not yet on disk
    # is named all the same. A file a person drops at the home's root outside the layout is
    # not a member and not protected.
    def protected_members
      [settings_path, binding_path, instance_path, connection_pointer_path, environment_path, conventions_path,
       connections_root, users_root, runners_root, mcp_root, adaptations_path, extensions_root, cache_root,
       tmp_root, log_root, File.join(@root, "telegram")]
    end

    def identity_work_root(user_public_id)
      File.join(@work_root, "users", segment(user_public_id))
    end

    # A runner has no user: its work root is keyed by the
    # address it registered.
    def runner_work_root(executor_public_id)
      File.join(@work_root, "runners", segment(executor_public_id))
    end

    # Rebuilt by the next boot, so they live in `tmp/`. The boot lock is
    # claimed before any identity is known, which is the whole reason this
    # scope exists (see Daemon).
    def boot_lock_path = File.join(tmp_root, "boot.lock")
    def announcement_path = File.join(tmp_root, "announcement.json")
    def host_cache_path(user_public_id) = File.join(tmp_root, "hosts", "#{segment(user_public_id)}.json")

    # A connection in flight. Durable on purpose: see the class comment.
    def connections_root = File.join(@root, "connections")
    def pending_connection_path = File.join(connections_root, "pending.json")

    # Which identity this home is currently connected as. A pointer rather
    # than a scan of `users/`: reconnecting as a different identity leaves the
    # previous root in place, so enumeration would be ambiguous exactly when it
    # mattered.
    def connection_pointer_path = File.join(@root, "connection.json")

    # Which Nexus this home is bound to. Written once and never rewritten:
    # a home holds one Nexus, and `resolve` refuses any other.
    def binding_path = File.join(@root, "nexus.json")

    # THE INSTANCE ID: the per-home part appended to the program's identifiers at pairing
    # (`rho.<id>`, `rho-runner.<id>`, `Connection`), so several installs of one program pair
    # under one steward as separate rows. Derived by the first `prepare` and kept by every
    # later one; a COPIED home answers the same id, so its pairing fences the original —
    # which is why a home is never copied. Not the connection pointer: that is written at
    # pairing, and the id must exist before it. nil before the first prepare; a file that
    # does not name an id is refused by path.
    def instance_path = File.join(@root, "instance.json")

    # THE MCP OAUTH CREDENTIALS: one
    # `Rho::StateFile` per server rho-mcp logged in to, `<key>.json` under
    # this directory — in the state root because a token is a person's
    # consent, not a rebuild; per server because the StateFile lock is
    # in-process and `rho mcp login` runs beside a daemon. rho reads
    # nothing inside; the path is rho-mcp's to use.
    def mcp_root = File.join(@root, "mcp")
    def mcp_credentials_dir = File.join(mcp_root, "credentials")

    def instance_id
      document = Rho::StateFile.new(instance_path).read
      return nil if document.nil?

      id = document["id"]
      unless document["version"] == INSTANCE_VERSION && id.is_a?(String) && INSTANCE_ID.match?(id)
        raise StateError, "state file #{instance_path} does not name this home's instance"
      end

      id
    end

    # OPERATOR SETTINGS, and the daemon writes it never. It sits beside the
    # binding rather than under `tmp/` because it is the one file here a
    # person authors, and it must survive the boot that rebuilds everything
    # rebuildable. Absent is the ordinary case: every key has a default.
    def settings_path = File.join(@root, "settings.json")

    # THE OPERATOR'S LOCAL ADAPTATION ROWS: the
    # default `adaptations_dir` — `<home>/adaptations/*.yml`, whole rows
    # in the SDK pack's format, read at boot beside the settings. Absent
    # is the ordinary case: the gem's rows alone.
    def adaptations_path = File.join(@root, "adaptations")

    # THE ONE KEY READ FRESH (correction (f)): the runner new
    # hosts start on, as the file says NOW — `rho runners use` writes it
    # from the CLI process while the daemon runs, so a boot-time copy would
    # be stale the moment a person chose. One small file read per `rho do`.
    def settings_runner
      value = Config.read(settings_path)["runner"].to_s
      value.empty? ? nil : value
    end

    def settings_workspace
      value = Config.read(settings_path)["workspace"].to_s
      value.empty? ? nil : value
    end

    # THE PERSON'S HAND ON THE PERSON'S FILE: one key merged into what
    # stands, written through a private temp file and renamed into place
    # (the state-file idiom, without its privacy refusal — an operator's
    # hand-authored 0644 file is theirs to keep; the rewrite is 0600), nil
    # deleting the key. Called by the CLI alone; the daemon never.
    def write_setting(key, value)
      settings = Config.read(settings_path)
      settings = value.nil? ? settings.except(key.to_s) : settings.merge(key.to_s => value)
      temp = "#{settings_path}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::EXCL, StateFile::PRIVATE_FILE_MODE) do |file|
        file.write(JSON.pretty_generate(settings))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.rename(temp, settings_path)
      settings
    ensure
      FileUtils.rm_f(temp) if temp
    end

    # EXTENSION CODE, in the STATE root rather than the work root. It
    # cannot be rebuilt and losing it changes what this daemon can do,
    # which is exactly the line the two roots are drawn on.
    def extensions_root = File.join(@root, "extensions")

    # WHAT THE API POINTED THE TOOLS AT. The daemon's own file, beside the
    # binding rather than under `tmp/`: it is a decision somebody made and
    # it must outlive the boot that rebuilds everything rebuildable.
    def environment_path = File.join(@root, "environment.json")

    # The connected Agent Profile's root.
    def identity_root(user_public_id)
      File.join(users_root, segment(user_public_id))
    end

    # A runner-mode home's root: a runner has no user, and the
    # user-keyed root would lie, so it is keyed by the address it registered.
    def runner_identity_root(executor_public_id)
      File.join(runners_root, segment(executor_public_id))
    end

    # Directories are created private and, where rho owns them outright, made
    # private even if they already existed. The chmod is not decoration: a
    # narrowing umask turns the requested 0700 into something like 0500, and a
    # directory rho cannot write into is one it can never put the next level
    # in. A pre-existing RHO_HOME is left as the operator set it — it may be a
    # deliberately shared parent, and everything inside it is protected on its
    # own terms.
    #
    # Both trees are prepared at boot, even though nothing writes work files
    # yet: a daemon that comes up should already have proved it can write
    # where it will need to. Discovering an unwritable volume hours later,
    # mid-task, is strictly worse than refusing to start.
    def prepare
      # The state root is narrowed even when the operator created it. Before
      # the per-Nexus layer was deleted, rho's own files sat one level deeper
      # in a directory it owned outright, so RHO_HOME could be a deliberately
      # shared parent; now the credential binding and connection pointer live
      # in the root itself, and StateFile refuses to
      # write into a directory others can read. A home is rho's directory by
      # definition, so this narrows rather than refusing to start.
      prepare_tree(@root, own: true)
      # The first boot derives the instance; every later one finds it.
      Rho::StateFile.new(instance_path)
        .create_once("version" => INSTANCE_VERSION, "id" => SecureRandom.hex(4))
      # Work holds nothing secret, so a shared volume stays as the operator
      # set it.
      prepare_tree(@work_root, own: false)
      [tmp_root, log_root].each do |directory|
        Dir.mkdir(directory, PRIVATE_DIRECTORY_MODE) unless File.directory?(directory)
        File.chmod(PRIVATE_DIRECTORY_MODE, directory)
      end
      Rho::StateFile.new(binding_path)
        .create_once("version" => BINDING_VERSION, "base_url" => @base_url)
      self
    end

    def inspect
      "#<Rho::Home root=#{@root.inspect} work_root=#{@work_root.inspect} base_url=#{@base_url.inspect}>"
    end
    alias_method :to_s, :inspect

    private

      def prepare_tree(root, own:)
        root_existed = File.directory?(root)
        FileUtils.mkdir_p(root, mode: PRIVATE_DIRECTORY_MODE)
        File.chmod(PRIVATE_DIRECTORY_MODE, root) if own || !root_existed
      end

      def segment(value)
        unless value.is_a?(String) && SAFE_SEGMENT.match?(value)
          raise ConfigurationError, "#{value.inspect} is not a usable identifier"
        end

        value
      end
  end
end
