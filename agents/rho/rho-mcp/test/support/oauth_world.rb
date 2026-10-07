require "net/http"
require "stringio"
require "tmpdir"
require_relative "oauth_fixture"
require_relative "loopback_server"

module McpTest
  # WHAT EVERY OAUTH TEST STANDS ON: the mock AS + RS under puma, a home
  # under a tmpdir with the credentials directory the real `Rho::StateFile`
  # writes into, one row for the fixture's `/mcp`, its storage, a
  # recording log, and the `$BROWSER` of the suite — a lambda that GETs the
  # authorization URL and follows the one redirect to the loopback
  # callback, as the harness's stub script will.
  module OauthWorld
    Home = Struct.new(:root, keyword_init: true) do
      def mcp_credentials_dir = File.join(root, "mcp", "credentials")
      def settings_path = File.join(root, "settings.json")
    end
    Cli = Struct.new(:out, :home, :daemon, :document, keyword_init: true) do
      def core = self
      def running_daemon = daemon
      def get(_daemon, _path) = :response
      def parse(_response) = document
    end

    FROZEN_NOW = Time.at(1_800_000_000)

    def oauth_setup(challenge: :oauth, tools: %w[echo lookup])
      @fixture = OauthFixture.new(server: FixtureServer.build(tools: tools), challenge: challenge)
      @puma, @base = LoopbackServer.start(@fixture)
      @root = File.realpath(Dir.mktmpdir("rho-mcp-oauth"))
      @home = Home.new(root: @root)
      @now = FROZEN_NOW
      @clock = -> { @now }
      @log = []
      log = @log
      @logger = Object.new
      %i[debug info warn error].each { |level| @logger.define_singleton_method(level) { |event, **f| log << [level, event, f] } }
      @row = oauth_row
      @storage = storage_for(@row)
      @connections = []
    end

    def oauth_teardown
      Array(@connections).each { |connection| connection.close rescue nil }
      LoopbackServer.stop(@puma) if @puma
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
      Rho::Mcp.reset!
    end

    def oauth_row(key: "fxo", **extra)
      raw = { "transport" => "http", "url" => "#{@base}/mcp", "tools" => ["*"], "timeout_ms" => 5000,
              "startup_timeout_ms" => 3000 }.merge(extra)
      Rho::Mcp::Settings.parse({ key => raw }, env: { "FX_TOKEN" => FX_TOKEN }).fetch(0)
    end

    def storage_for(row) = Rho::Mcp::Oauth.storage_for(row, home: @home, log: @logger, clock: @clock)

    def credential_path(key = "fxo") = File.join(@home.mcp_credentials_dir, "#{key}.json")

    def document(key = "fxo") = JSON.parse(File.read(credential_path(key)))

    def cli(daemon: nil, document: nil) = Cli.new(out: StringIO.new, home: @home, daemon: daemon, document: document)

    # The suite's browser: the authorization URL fetched, its redirect to
    # the loopback callback followed, nothing printed.
    def browser = ->(url) { follow(url) }

    def follow(url)
      response = Net::HTTP.get_response(URI(url))
      Net::HTTP.get_response(URI(response["location"])) if response.is_a?(Net::HTTPRedirection)
    end

    def login!(row: @row, storage: @storage, options: {}, browser: self.browser, input: nil, callback: nil, cli: self.cli)
      Rho::Mcp::Oauth::Login.call(cli, row, storage, options, browser: browser, input: input, callback: callback)
      cli
    end

    def connection(storage: @storage, row: @row)
      Rho::Mcp::Connection.new(row, log: @logger, redact: Rho::Runner::Redact.new(row.secrets, live: storage),
        transport_factory: Rho::Mcp.transport_factory, clock: @clock, storage: storage).tap { |c| @connections << c }
    end

    def call(connection, raw, args = {})
      Rho::Runner::ExecutionContext.with(Rho::Runner::ExecutionContext.new(task_key: "t1")) do
        connection.call_tool(raw, args, public_name: "mcp__fxo__#{raw}")
      end
    end

    def switch!(name, value = "on")
      Net::HTTP.post(URI("#{@base}/fixture/#{name}"), value.to_s)
    end

    def issued = @fixture.issued

    def log_events(event) = @log.select { |entry| entry[1] == event }
  end
end
