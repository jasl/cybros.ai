require "tmpdir"
require "open3"
require "support/turn_certificate"
require "rho/env/webrtc_connection"

module E2E
  class WebrtcFixture
    def self.open(address: "127.0.0.1", transport: "udp")
      Dir.mktmpdir("rho-webrtc") do |directory|
        root = File.expand_path("../../..", __dir__)
        binary = File.join(directory, "peer")
        turn = File.join(directory, "turn")
        build(root, "agents/rho/rho-env/transport", binary, ".")
        build(root, "e2e/products/manual/realtime_transport", turn, "./cmd/turnfixture")
        options = []
        if transport == "tls"
          material = TurnCertificate.write(directory, address: address)
          options = ["--certificate", material.certificate, "--key", material.key]
        end
        errors = File.join(directory, "turn.log")
        Open3.popen2(turn, "--address", address, "--transport", transport, *options, err: errors) do |input, output, process|
          begin
            yield new(binary, output.gets.strip, errors: errors, certificate: material&.certificate)
          ensure
            input.close
            process.value
          end
        end
      end
    end

    def self.build(root, directory, binary, package)
      output, status = Open3.capture2e("go", "build", "-o", binary, package, chdir: File.join(root, directory))
      raise "WebRTC fixture build failed: #{output}" unless status.success?
    end

    def initialize(binary, url, errors:, certificate:)
      @certificate = certificate
      @errors = errors
      @binary = binary
      @servers = [{ "urls" => [url], "username" => "fixture", "credential" => "isolated-fixture" }]
    end

    attr_reader :servers, :binary, :certificate

    def errors = File.read(@errors)

    def connection(context:)
      Rho::Env::WebrtcConnection.new(executable: @binary, context: context, servers: @servers)
    end

    def peer(context: nil)
      Rho::Env::WebrtcTransport.new(executable: @binary, context: context)
    end
  end
end
