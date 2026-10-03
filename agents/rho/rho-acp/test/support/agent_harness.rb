require "stringio"
require "tmpdir"

module RhoAcpTest
  # THE AGENT ON A PIPE PAIR: the surface served on a thread over one
  # `Wire`, and a CLIENT `Rho::Acp::Connection` on the other end — the
  # landed loop plays the editor. The client's drain thread collects every
  # `session/update` (`updates`), answers the agent's requests through
  # `policy` (a callable given the `Inbound`; the default answers -32601)
  # or HOLDS them on `held` when `policy` is `:hold`, so a test can watch
  # the agent's cancel cascade. Every wait is bounded.
  class AgentHarness
    Agent = Rho::Acp::Agent
    Methods = Rho::Acp::Methods
    TIMEOUT = 5
    CLIENT_NAME = "test-editor".freeze

    attr_reader :agent, :client, :core, :err, :updates, :held, :notifications, :home
    attr_accessor :policy

    def self.capabilities(read: false, write: false, form: false, url: false, terminal_auth: false)
      {
        "fs" => { "readTextFile" => read, "writeTextFile" => write },
        "terminal" => false,
        "auth" => { "terminal" => terminal_auth },
        "elicitation" => { "form" => form ? {} : nil, "url" => url ? {} : nil }.compact,
      }
    end

    def initialize(core:, mode: Agent::DEFAULT_MODE, model: nil, runner: nil, home: nil)
      @core = core
      @home = home || RhoAcpTest.home
      @err = StringIO.new
      agent_in, client_out = IO.pipe
      client_in, agent_out = IO.pipe
      @agent = Agent.new(wire: Rho::Acp::Wire.new(input: agent_in, output: agent_out), core: -> { @core },
        home: @home, mode: mode, model: model, runner: runner, log: @err)
      @serving = Thread.new { @agent.serve }
      @serving.name = "harness-agent"
      @client = Rho::Acp::Connection.new(Rho::Acp::Wire.new(input: client_in, output: client_out))
      @updates = []
      @notifications = []
      @held = Queue.new
      @policy = ->(inbound) { inbound.fail(Methods::ErrorCode::METHOD_NOT_FOUND, "Method not found") }
      @lock = Mutex.new
      @drain = Thread.new { drain }
      @drain.name = "harness-client"
    end

    # ---- the client's verbs ----

    def request(method, params = nil, timeout: TIMEOUT)
      @client.request(method, params).wait(timeout: timeout)
    end

    # The error the agent answered, as a `RemoteError`.
    def refused(method, params = nil, timeout: TIMEOUT)
      request(method, params, timeout: timeout)
      raise "#{method} was not refused"
    rescue Rho::Acp::RemoteError => error
      error
    end

    def notify(method, params = nil) = @client.notify(method, params)

    def initialize_agent(capabilities: self.class.capabilities, name: CLIENT_NAME)
      request(Methods::INITIALIZE, {
        "protocolVersion" => Methods::PROTOCOL_VERSION, "clientCapabilities" => capabilities,
        "clientInfo" => { "name" => name, "title" => "Test editor", "version" => "0" },
      })
    end

    def new_session(cwd:, servers: [], extra: {})
      request(Methods::SESSION_NEW, { "cwd" => cwd, "mcpServers" => servers }.merge(extra))
    end

    def prompt(session, text, timeout: TIMEOUT)
      blocks = text.is_a?(Array) ? text : [{ "type" => "text", "text" => text }]
      request(Methods::SESSION_PROMPT, { "sessionId" => session, "prompt" => blocks }, timeout: timeout)
    end

    def start_prompt(session, text)
      blocks = text.is_a?(Array) ? text : [{ "type" => "text", "text" => text }]
      @client.request(Methods::SESSION_PROMPT, { "sessionId" => session, "prompt" => blocks })
    end

    # ---- what the agent sent ----

    def updates_of(kind)
      @lock.synchronize { @updates.select { |params| params.dig("update", Methods::SESSION_UPDATE_DISCRIMINATOR) == kind } }
    end

    def await_update(kind, timeout: TIMEOUT)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        found = updates_of(kind).first
        return found if found
        raise "no #{kind} within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end
    end

    def await_held(timeout: TIMEOUT)
      inbound = @held.pop(timeout: timeout)
      raise "no request was held within #{timeout}s" if inbound.nil?

      inbound
    end

    def stderr = @err.string

    # EOF on the agent's stdin, the serve thread joined.
    def close
      @client.close
      @serving.join(TIMEOUT)
      @drain.join(1)
      nil
    end

    private

      def drain
        while (event = @client.receive)
          case event
          when Rho::Acp::Connection::Inbound then serve_inbound(event)
          when Rho::Acp::Wire::Notification
            @lock.synchronize do
              @notifications << event
              @updates << event.params if event.method == Methods::SESSION_UPDATE
            end
          else nil
          end
        end
      end

      def serve_inbound(inbound)
        if @policy == :hold
          @held << inbound
        else
          @policy.call(inbound)
        end
      rescue StandardError => error
        inbound.fail(Methods::ErrorCode::INTERNAL, "#{error.class}: #{error.message}") unless inbound.answered?
      end
  end

  # A throwaway home for the attachments' tmp dir.
  def self.home
    Rho::Home.resolve(base_url: "https://nexus.example", root: Dir.mktmpdir("rho-acp-home"))
  end

  # A permission policy answering `option_id` to every request.
  def self.permission_policy(option_id)
    lambda do |inbound|
      if inbound.method == Rho::Acp::Methods::SESSION_REQUEST_PERMISSION
        inbound.respond("outcome" => { "outcome" => "selected", "optionId" => option_id })
      else
        inbound.fail(Rho::Acp::Methods::ErrorCode::METHOD_NOT_FOUND, "Method not found")
      end
    end
  end
end
