require "httpx"
require "json"
require "fileutils"
require "uri"

# Deployment-operator orchestration, run inside the Nexus image. Only rho's
# authenticated control response selects the grant; public device requests,
# including requests copying its identifiers, are never an approval queue.
class CybrosStackSetup
  class Error < StandardError; end

  def initialize
    @http = HTTPX.with(timeout: { connect_timeout: 5, operation_timeout: 10 })
    @rho_url = ENV.fetch("RHO_SETUP_URL", "http://rho:7777")
    @announcement_path = ENV.fetch("RHO_SETUP_ANNOUNCEMENT", "/var/lib/rho-tmp/announcement.json")
    @status_path = ENV.fetch("RHO_INSTALLATION_FILE", "/var/lib/cybros-setup/status.json")
  end

  def call
    @nexus_ready = database { Account.exists? }
    publish_status
    puts "Waiting for the first Nexus account. Continue from rho in your browser."
    # First boot is a human-paced wait; no device grant exists until it finishes.
    until @nexus_ready
      sleep 2
      @nexus_ready = database { Account.exists? }
    end
    publish_status
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
    until paired?
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Error, "Automatic pairing timed out. Check rho and Nexus, then run ./cybros up to retry."
      end
      sleep 2
    end
    puts "rho Agent and private Runner are connected. Continue in rho Settings."
  rescue Error => error
    publish_status(error: error.message)
    raise
  ensure
    @http.close
  end

  private

    # This file only projects installation facts for rho's authenticated page.
    # Account and device credentials remain the readiness authorities.
    def publish_status(error: nil)
      document = { nexus_ready: @nexus_ready, setup_url: @nexus_ready ? nil : setup_url, error: error }
      FileUtils.mkdir_p(File.dirname(@status_path), mode: 0o700)
      temporary = "#{@status_path}.new"
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(JSON.generate(document))
        file.write("\n")
      end
      File.rename(temporary, @status_path)
    end

    def setup_url
      base = ENV.fetch("BASE_URL").delete_suffix("/")
      fragment = URI.encode_www_form_component(ENV.fetch("NEXUS_SETUP_SECRET"))
      "#{base}/setup#setup_secret=#{fragment}"
    end

    def paired?
      status = request("GET", "/status")
      return false unless status

      raise Error, "Automatic pairing requires the bundled full-mode rho." unless status.fetch("mode") == "full"
      planes = status.dig("authority", "planes") || {}
      if %w[member executor_transport runner_transport].all? { |plane| planes[plane] == "live" } &&
          status.dig("identity", "executor_public_id") && status.dig("identity", "runner_executor_public_id")
        true
      else
        if @authorization_id
          database { connect_grant }
        else
          started = request("POST", "/device/start")
          if started && started["user_code"]
            database do
              authorization = Account.first.device_authorizations.find_live_by_user_code(started.fetch("user_code"))
              @authorization_id = authorization&.public_id
              connect_grant if @authorization_id
            end
          end
        end
        false
      end
    end

    def connect_grant
      account = Account.first
      authorization = account.device_authorizations.find_by!(public_id: @authorization_id)
      case authorization.status
      when "pending"
        unless authorization.combined_connection?
          raise Error, "This rho needs a manual reconnect. Run ./cybros connect."
        end
        # First installation may create registrations, but a rerun must never
        # undo a disconnect, revocation, removal, or stewardship transfer.
        if account.users.exists?(agent_identifier: authorization.agent_identifier) ||
            account.task_executors.exists?(runner_identifier: authorization.runner_identifier)
          raise Error, "Existing rho registration requires a manual reconnect. Run ./cybros connect."
        end
        result = DeviceAuthorizations::Connect.call(authorization: authorization, connector: account.owner)
        unless %i[connected stale].include?(result.outcome)
          raise Error, "Nexus could not approve initial pairing. Check the owner account, then run ./cybros connect."
        end
      when "connected", "consumed"
        # The ordinary device poll and rho's durable staging own consumption
        # and activation, including recovery after either process restarts.
        unless authorization.connected_by_id == account.owner.id
          raise Error, "Pairing was connected by another member. Complete that connection manually."
        end
      else
        raise Error, "Initial pairing ended before activation. Run ./cybros up to retry."
      end
    end

    def request(method, path)
      @bearer ||= announcement_bearer
      return nil unless @bearer

      response = exchange(method, path, headers: { "authorization" => "Bearer #{@bearer}" })
      return nil unless response

      case response.status
      when 200
        document(response)
      when 401
        # A restart rotates the bearer and may lose a pre-consume device code.
        # Rejoin that daemon's current ceremony after its normal boot recovery.
        @bearer = nil
        @authorization_id = nil
      when 409
        if document(response).dig("error", "code") != "already_connected"
          raise Error, "rho refused automatic pairing. Run ./cybros connect."
        end
        nil
      else
        raise Error, "rho refused a setup request (HTTP #{response.status}). Check ./cybros logs rho."
      end
    end

    # The deployment operator has the same private local authority as rho's
    # CLI. The user's editable access password is not a pairing credential.
    def announcement_bearer
      bearer = JSON.parse(File.read(@announcement_path)).to_h.fetch("bearer").to_s
      if bearer.empty?
        raise Error, "rho's local control credentials are missing. Check ./cybros logs rho, then run ./cybros up."
      end
      bearer
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError, TypeError, NoMethodError, KeyError
      raise Error, "rho's local control credentials are invalid. Check ./cybros logs rho, then run ./cybros up.", cause: nil
    end

    def exchange(method, path, **options)
      response = @http.request(method, "#{@rho_url}#{path}", **options)
      return nil if response in HTTPX::ErrorResponse

      # Startup/restart and an unavailable Nexus are recoverable within this
      # attempt's deadline. No redirect or library retry is enabled.
      response unless [502, 503, 504].include?(response.status)
    rescue SystemCallError, SocketError, IOError
      # HTTPX can raise raw socket failures while the daemon is restarting.
      nil
    end

    def document(response)
      JSON.parse(response.body.to_s).to_h
    rescue JSON::ParserError, TypeError, NoMethodError
      raise Error, "rho returned an invalid setup response.", cause: nil
    end

    def database(&block)
      # Rails runner wraps this whole process in one executor context. Polls
      # must see the browser's writes rather than that context's query cache.
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.uncached(&block)
      end
    end
end

if $PROGRAM_NAME == __FILE__
  begin
    $stdout.sync = true
    CybrosStackSetup.new.call
  rescue CybrosStackSetup::Error => error
    abort error.message
  end
end
