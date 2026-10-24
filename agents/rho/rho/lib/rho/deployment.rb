require "json"
require "rbconfig"
require "securerandom"
require "timeout"

module Rho
  # The installation updater owns releases, preflight and durable receipts.
  # rho's local operator surface selects only rho; the packaged helper owns
  # its IPC protocol. No Docker authority or upgrade state lives in rho.
  class Deployment
    HELPER = "/usr/local/share/cybros/updater/updater.rb".freeze
    REQUEST_LIMIT = 16 * 1024
    RESPONSE_LIMIT = 128 * 1024

    def self.register(api)
      deployment = new
      api.register_route("GET", "/deployment") { |_request, _context| deployment.status }
      api.register_route("POST", "/deployment/check") do |request, _context|
        deployment.check(ControlServer.json_body(request).fetch("tag", "latest").to_s)
      end
      api.register_route("POST", "/deployment/upgrade") do |request, _context|
        deployment.upgrade(ControlServer.json_body(request))
      end
      api.register_route("GET", "/deployment/receipt") do |request, _context|
        deployment.receipt(ControlServer.query(request)["operation_id"].to_s)
      end
      api.register_route("GET", "/deployment/log") do |request, _context|
        query = ControlServer.query(request)
        deployment.log(query["operation_id"].to_s, query["cursor"])
      end
    end

    def initialize(environment: ENV, helper: HELPER)
      @socket = environment["RHO_DEPLOYMENT_SOCKET"].to_s
      @helper = helper
      @mode = if environment["RHO_CONTAINER"] == "1"
        "container"
      elsif Install.installed?(environment)
        "installed"
      else
        "checkout"
      end
    end

    def status
      if @socket.empty?
        [200, { "supported" => false, "mode" => @mode }]
      else
        request("status")
      end
    end

    def check(tag)
      status, body = request("check", "tag" => tag, "backup" => false)
      # One key for the checked choice, kept by the page across an ambiguous
      # submit. The updater's receipt is the only durable acceptance record.
      body = body.merge("idempotency_key" => SecureRandom.uuid_v7) if status == 200
      [status, body]
    end

    def upgrade(document)
      candidate = document.fetch("candidate").to_h.slice("release", "images")
      request("upgrade", "candidate" => candidate, "idempotency_key" => document.fetch("idempotency_key"),
        "backup" => false, "actor_public_id" => nil)
    rescue KeyError, TypeError, NoMethodError
      Daemon::Refusal.new(status: 400, code: "invalid_request", message: "Select a checked rho release before upgrading.")
    end

    def receipt(operation_id) = request("receipt", "operation_id" => operation_id)
    def log(operation_id, cursor) = request("log", "operation_id" => operation_id, "cursor" => cursor)

    private

    def request(operation, attributes = {})
      if @socket.empty?
        return Daemon::Refusal.new(status: 409, code: "deployment_unsupported", message: "Use this installation's update tools to upgrade rho.")
      end

      bytes = JSON.generate(attributes.merge("operation" => operation, "scope" => "rho"))
      if bytes.bytesize > REQUEST_LIMIT
        return Daemon::Refusal.new(status: 400, code: "invalid_request", message: "The deployment request exceeds its size limit.")
      end

      Timeout.timeout(operation == "check" ? 130 : 10) do
        child = Env::Subprocess.start({ "CYBROS_UPDATER_SOCKET" => @socket }, RbConfig.ruby, @helper, "request")
        begin
          child.stdin.write(bytes)
          child.stdin.close
          output = child.stdout.read(RESPONSE_LIMIT + 1)
          raise IOError, "oversized response" if output.bytesize > RESPONSE_LIMIT

          child.wait
          response = JSON.parse(output).to_h
          status = Integer(response.fetch("status"))
          raise ArgumentError, "invalid response status" unless (200..599).cover?(status)

          [status, status < 400 ? response.fetch("data").to_h : { "error" => response.fetch("error").to_h }]
        ensure
          child.cleanup
        end
      end
    rescue Timeout::Error, JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError, IOError, SystemCallError
      Daemon::Refusal.new(status: 503, code: "updater_unavailable",
        message: "The installation updater is unavailable. Check its status on the deployment host.")
    end
  end
end
