require "support/webrtc_fixture"
require "rho/runner/webrtc_connection"
require "shellwords"
require "support/turn_certificate"

module E2E
  # Only these disposable network namespaces receive firewall changes.
  class WebrtcNetworkFixture
    def self.open(transport: "udp")
      Dir.mktmpdir("rho-webrtc-network") do |directory|
        fixture = new(directory, transport: transport)
        begin
          fixture.start
          yield fixture
        ensure
          fixture.close
        end
      end
    end

    def initialize(directory, transport:)
      raise ArgumentError, "transport must be udp, tcp or tls" unless %w[udp tcp tls].include?(transport)

      @transport = transport
      @directory = directory
      @name = "rho-webrtc-#{SecureRandom.hex(6)}"
      @containers = []
      @addresses = {}
      @wrappers = {}
    end

    attr_reader :servers

    def start
      root = File.expand_path("../..", __dir__)
      docker("build", "-q", "-t", "cybros-e2e/webrtc-network", File.join(__dir__, "webrtc_network"))
      architecture = docker("info", "--format", "{{.Architecture}}").strip
      arch = { "aarch64" => "arm64", "arm64" => "arm64", "x86_64" => "amd64" }.fetch(architecture)
      { "transport" => ["agents/rho/rho-runner/transport", "."],
        "turn" => ["e2e/manual/realtime_transport", "./cmd/turnfixture"] }.each do |name, (path, package)|
        output, status = Open3.capture2e({ "GOOS" => "linux", "GOARCH" => arch, "CGO_ENABLED" => "0" },
          "go", "build", "-o", File.join(@directory, name), package, chdir: File.join(root, path))
        raise "WebRTC fixture build failed: #{output}" unless status.success?
      end
      docker("network", "create", @name)
      %w[turn runner member].each do |role|
        name = "#{@name}-#{role}"
        docker("run", "-d", "--name", name, "--network", @name, "--cap-add=NET_ADMIN", "cybros-e2e/webrtc-network")
        @containers << name
        @addresses[role] = docker("inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", name).strip
        binary = role == "turn" ? "turn" : "transport"
        docker("cp", File.join(@directory, binary), "#{name}:/#{binary}")
        @wrappers[role] = peer_wrapper(role) unless role == "turn"
      end
      tls_options = @transport == "tls" ? prepare_tls : []
      @turn_input, @turn_output, @turn_process = Open3.popen2("docker", "exec", "-i", "#{@name}-turn", "/turn",
        "-address", @addresses.fetch("turn"), "-transport", @transport, *tls_options)
      raise "TURN fixture did not start" unless @turn_output.wait_readable(10)

      @servers = [{ "urls" => [@turn_output.gets.strip], "username" => "fixture", "credential" => "isolated-fixture" }]
    end

    def connection(context:)
      Rho::Runner::WebrtcConnection.new(executable: @wrappers.fetch("runner"), context: context, servers: @servers)
    end

    def peer(role: "member", trusted: true)
      executable = trusted ? @wrappers.fetch(role) : peer_wrapper(role, trusted: false)
      Rho::Runner::WebrtcTransport.new(executable: executable)
    end

    def block_direct
      { "runner" => "member", "member" => "runner" }.each do |role, other|
        docker("exec", "#{@name}-#{role}", "iptables", "-A", "OUTPUT", "-p", "udp", "-d", @addresses.fetch(other), "-j", "DROP")
      end
    end

    def block_udp
      %w[runner member].each do |role|
        docker("exec", "#{@name}-#{role}", "iptables", "-A", "OUTPUT", "-p", "udp", "-j", "DROP")
        # A non-terminating counter for this exact TURN destination.
        docker("exec", "#{@name}-#{role}", "iptables", "-A", "OUTPUT", "-p", "tcp", "-d", @addresses.fetch("turn"))
      end
    end

    def relay_tcp_packets(role)
      docker("exec", "#{@name}-#{role}", "iptables", "-L", "OUTPUT", "-nvx").lines.filter_map do |line|
        fields = line.split
        fields.first.to_i if fields[2] == "tcp" && fields.last == @addresses.fetch("turn")
      end.sum
    end

    def block_relay
      %w[runner member].each do |role|
        docker("exec", "#{@name}-#{role}", "iptables", "-A", "OUTPUT", "-p", @transport == "udp" ? "udp" : "tcp", "-d", @addresses.fetch("turn"), "-j", "DROP")
      end
    end

    def unblock_relay
      %w[runner member].each do |role|
        docker("exec", "#{@name}-#{role}", "iptables", "-D", "OUTPUT", "-p", @transport == "udp" ? "udp" : "tcp", "-d", @addresses.fetch("turn"), "-j", "DROP")
      end
    end

    def dropped_packets(role)
      docker("exec", "#{@name}-#{role}", "iptables", "-L", "OUTPUT", "-nvx").lines.filter_map do |line|
        fields = line.split
        fields.first.to_i if fields[2] == "DROP"
      end.sum
    end

    def helpers_reaped?
      %w[runner member].all? do |role|
        output, status = Open3.capture2e("docker", "exec", "#{@name}-#{role}", "pidof", "transport")
        raise "Cannot inspect fixture helper: #{output}" unless [0, 1].include?(status.exitstatus)

        status.exitstatus == 1
      end
    end

    def close
      @turn_input&.close
      @containers.reverse_each { |name| Open3.capture2e("docker", "rm", "-f", name) }
      @turn_output&.close
      @turn_process&.value
      Open3.capture2e("docker", "network", "rm", @name)
    end

    private

      def peer_wrapper(role, trusted: true)
        wrapper = File.join(@directory, "#{role}-#{trusted}-exec")
        options = @transport == "tls" && trusted ? ["-e", "SSL_CERT_FILE=/turn-ca.pem"] : []
        command = ["docker", "exec", "-i", *options, "#{@name}-#{role}", "sh", "/peer.sh"]
        File.write(wrapper, "#!/bin/sh\nexec #{Shellwords.join(command)}\n")
        File.chmod(0o700, wrapper)
        wrapper
      end

      def prepare_tls
        material = TurnCertificate.write(@directory, address: @addresses.fetch("turn"))
        cert_path, key_path = material.certificate, material.key
        %w[turn runner member].each { |role| docker("cp", cert_path, "#{@name}-#{role}:/turn-ca.pem") }
        docker("cp", key_path, "#{@name}-turn:/turn-key.pem")
        ["-certificate", "/turn-ca.pem", "-key", "/turn-key.pem"]
      end

      def docker(*args)
        output, status = Open3.capture2e("docker", *args)
        raise "WebRTC fixture Docker command failed: #{output}" unless status.success?

        output
      end
  end
end
