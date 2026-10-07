require "cybros_agent"
require "time"

module Rho
  # Where one connection's credentials belong, and the durable facts recorded
  # beside them.
  #
  # The destination is never named by the token response — it carries no
  # identity at all — so it comes from a bootstrap read against the credentials
  # themselves:
  #
  # `/profile` supplies the Agent user's public id, while `/executor` supplies
  # this Agent application's delivery address. `/profile` names no address at
  # all: a profile has at most one, and the sibling transport credential names
  # the current one.
  #
  # THE PAIRED MODE RIDES THE POINTER: `full` and `agent`
  # identities are the Profile's, keyed by its user; a `runner` identity has
  # no user and lives under a runner root keyed by the address it registered.
  # The runner lineage always lives in `runner_credentials.json` — beside
  # `credentials.json` in full mode, alone under the runner root in runner
  # mode. Format 4 names the mode; an older pointer is refused, never read
  # with a fallback (no compat before release).
  class Identity
    SESSION_VERSION = 4
    MODES = Config::MODES

    attr_reader :root, :user_public_id, :executor_public_id, :mode, :runner_executor_public_id

    def self.agent(home:, user_public_id:, executor_public_id:, mode:, runner_executor_public_id: nil)
      user_public_id = validate_public_id!(
        user_public_id, label: "Agent user", error_class: ConfigurationError
      )
      executor_public_id = validate_public_id!(
        executor_public_id, label: "Agent executor", error_class: ConfigurationError
      )
      unless runner_executor_public_id.nil?
        runner_executor_public_id = validate_public_id!(
          runner_executor_public_id, label: "Runner executor", error_class: ConfigurationError
        )
      end
      new(
        home: home, root: home.identity_root(user_public_id), mode: validate_mode!(mode, %w[full agent]),
        user_public_id: user_public_id, executor_public_id: executor_public_id,
        runner_executor_public_id: runner_executor_public_id
      )
    end

    # Runner mode's identity: no user, the one address is the runner's.
    def self.runner(home:, executor_public_id:)
      executor_public_id = validate_public_id!(
        executor_public_id, label: "Runner executor", error_class: ConfigurationError
      )
      new(
        home: home, root: home.runner_identity_root(executor_public_id), mode: "runner",
        user_public_id: nil, executor_public_id: executor_public_id,
        runner_executor_public_id: executor_public_id
      )
    end

    # Rebuild from the home's pointer, which is how a booting daemon
    # finds the connection it already has without a second ceremony.
    def self.from_pointer(home:, pointer:)
      unless pointer["version"] == SESSION_VERSION
        raise StoredConnectionError,
          "the connection pointer is not format version #{SESSION_VERSION}"
      end

      mode = pointer.fetch("mode") { raise StoredConnectionError, "the connection pointer names no mode" }
      if mode == "runner"
        runner(home: home, executor_public_id: pointer.fetch("executor_public_id"))
      else
        agent(
          home: home, user_public_id: pointer.fetch("user_public_id"),
          executor_public_id: pointer.fetch("executor_public_id"), mode: mode,
          runner_executor_public_id: pointer["runner_executor_public_id"]
        )
      end
    rescue KeyError
      raise StoredConnectionError, "the connection pointer is missing an Agent identity public id"
    rescue ConfigurationError => error
      raise StoredConnectionError, error.message
    end

    def self.validate_public_id!(public_id, label:, error_class:)
      return public_id if public_id.is_a?(String) && !public_id.empty?

      raise error_class, "#{label} public id must be a non-empty String"
    end

    def self.validate_mode!(mode, words)
      return mode if words.include?(mode)

      raise ConfigurationError, "mode must be one of #{words.join(", ")}, got #{mode.inspect}"
    end

    def initialize(home:, root:, mode:, user_public_id:, executor_public_id:, runner_executor_public_id:)
      @home = home
      @root = root
      @mode = mode
      @user_public_id = user_public_id
      @executor_public_id = executor_public_id
      @runner_executor_public_id = runner_executor_public_id
    end

    def vault = Rho::StateFile.new(File.join(@root, "credentials.json"))
    def runner_vault = Rho::StateFile.new(File.join(@root, "runner_credentials.json"))
    def session = Rho::StateFile.new(File.join(@root, "session.json"))

    def public_id = @user_public_id || @executor_public_id

    def runner_mode? = @mode == "runner"

    # Where this identity's tools land by default: the Profile's work root,
    # or the runner's own.
    def work_root
      runner_mode? ? @home.runner_work_root(@executor_public_id) : @home.identity_work_root(@user_public_id)
    end

    # The same Profile, now serving a runner too (agent→full, the runner-only
    # ceremony's install) — and the reverse (`rho disconnect --runner`).
    def with_runner(runner_executor_public_id)
      self.class.agent(
        home: @home, user_public_id: @user_public_id, executor_public_id: @executor_public_id,
        mode: "full", runner_executor_public_id: runner_executor_public_id
      )
    end

    def without_runner
      self.class.agent(
        home: @home, user_public_id: @user_public_id, executor_public_id: @executor_public_id, mode: "agent"
      )
    end

    def pointer_document
      {
        "version" => SESSION_VERSION,
        "mode" => @mode,
        "user_public_id" => @user_public_id,
        "executor_public_id" => @executor_public_id,
        "runner_executor_public_id" => @runner_executor_public_id,
      }.compact
    end

    def prepare
      FileUtils.mkdir_p(@root, mode: Home::PRIVATE_DIRECTORY_MODE)
      File.chmod(Home::PRIVATE_DIRECTORY_MODE, @root)
      self
    end

    # The identity root records which Nexus it belongs to, and a mismatch fails
    # closed rather than adopting another home's credentials — a moved or
    # hand-copied directory would
    # otherwise look native.
    def record(clock:)
      document = pointer_document.merge(
        "base_url" => @home.base_url,
        "connected_at" => clock.call.utc.iso8601
      )
      session.write(document)
      self
    end

    # Every pointer field is compared — the mode among them, so a home paired
    # in one mode and booted in another fails closed for free.
    def verify_belongs_here
      document = session.read
      if document.nil?
        raise StoredConnectionError, "#{@root} has no recorded Agent session"
      end

      unless document["base_url"] == @home.base_url
        raise StoredConnectionError,
          "#{@root} was connected to a different Nexus than #{@home.base_url}"
      end
      expected = pointer_document.merge("base_url" => @home.base_url)
      expected.each do |field, value|
        unless document[field] == value
          raise StoredConnectionError,
            "#{@root} does not match the connection pointer's #{field}"
        end
      end

      self
    end

    # A newly consumed bundle already proved which Agent user and executor it
    # belongs to through the two bootstrap reads. It may replace the current
    # executor for that SAME user: terminally revoking an address makes the
    # next Consume create a new one, while the user-scoped identity root stays
    # the same. This check therefore protects the root's Nexus and user
    # ownership without imposing boot's stricter "pointer equals session"
    # rule on a legitimate executor rollover.
    def verify_installable
      document = session.read
      return self if document.nil?

      expected = {
        "version" => SESSION_VERSION,
        "base_url" => @home.base_url,
        "user_public_id" => @user_public_id,
      }
      expected.each do |field, value|
        unless document[field] == value
          description =
            field == "base_url" ? "a different Nexus than #{@home.base_url}" : "another #{field}"
          raise StoredConnectionError, "#{@root} was connected to #{description}"
        end
      end
      self.class.validate_public_id!(
        document["executor_public_id"],
        label: "Stored Agent executor",
        error_class: StoredConnectionError
      )

      self
    end

    def inspect = "#<Rho::Identity mode=#{@mode} public_id=#{public_id.inspect}>"
    alias_method :to_s, :inspect
  end
end
