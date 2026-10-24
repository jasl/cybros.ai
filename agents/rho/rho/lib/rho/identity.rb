require "cybros_agent"
require "time"

module Rho
  class Identity
    SESSION_VERSION = 6

    attr_reader :root, :user_public_id, :executor_public_id, :agent_identifier

    def self.agent(home:, user_public_id:, executor_public_id:, agent_identifier: nil)
      user_public_id = validate_public_id!(
        user_public_id, label: "Agent user", error_class: ConfigurationError
      )
      executor_public_id = validate_public_id!(
        executor_public_id, label: "Agent executor", error_class: ConfigurationError
      )
      new(
        home: home, root: home.identity_root(user_public_id),
        user_public_id: user_public_id, executor_public_id: executor_public_id,
        agent_identifier: agent_identifier
      )
    end

    # Rebuild from the home's pointer, which is how a booting daemon
    # finds the connection it already has without a second ceremony.
    def self.from_pointer(home:, pointer:)
      unless pointer["version"] == SESSION_VERSION
        raise StoredConnectionError,
          "the connection pointer is not format version #{SESSION_VERSION}"
      end

      agent(home: home, user_public_id: pointer.fetch("user_public_id"),
        executor_public_id: pointer.fetch("executor_public_id"), agent_identifier: pointer["agent_identifier"])
    rescue KeyError
      raise StoredConnectionError, "the connection pointer is missing an Agent identity public id"
    rescue ConfigurationError => error
      raise StoredConnectionError, error.message
    end

    def self.validate_public_id!(public_id, label:, error_class:)
      public_id = String.try_convert(public_id)
      return public_id if public_id && !public_id.empty?

      raise error_class, "#{label} public id must be a non-empty String"
    end

    def initialize(home:, root:, user_public_id:, executor_public_id:,
      agent_identifier: nil)
      @home = home
      @root = root
      @user_public_id = user_public_id
      @executor_public_id = executor_public_id
      @agent_identifier = agent_identifier
    end

    def vault = Rho::StateFile.new(File.join(@root, "credentials.json"))
    def session = Rho::StateFile.new(File.join(@root, "session.json"))

    def public_id = @user_public_id

    def runner_executor_public_id = @executor_public_id

    def work_root = @home.identity_work_root(@user_public_id)

    def pointer_document
      {
        "version" => SESSION_VERSION,
        "user_public_id" => @user_public_id,
        "executor_public_id" => @executor_public_id,
        "agent_identifier" => @agent_identifier,
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

    # The pointer and recorded session must describe the same application.
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

    def inspect = "#<Rho::Identity public_id=#{public_id.inspect}>"
    alias_method :to_s, :inspect
  end
end
