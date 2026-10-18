require "test_helper"
require "socket"

class ModelProviders::CodexAuthorization::TransportTest < ActiveSupport::TestCase
  def test_same_origin_alt_svc_does_not_delay_a_completed_response
    context = local_tls_context
    context.alpn_select_cb = ->(_protocols) { "http/1.1" }
    trust = OpenSSL::X509::Store.new
    trust.add_cert(context.cert)
    listener = TCPServer.new("127.0.0.1", 0)
    delivered = Queue.new
    release = Queue.new
    server = Thread.new do
      socket = OpenSSL::SSL::SSLSocket.new(listener.accept, context)
      socket.sync_close = true
      socket.accept
      while (line = socket.gets)
        break if line == "\r\n"
      end
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nAlt-Svc: h3=\":#{listener.addr[1]}\"; ma=60\r\n\r\n{}")
      delivered << true
      release.pop
    ensure
      socket&.close
    end

    original_with = HTTPX.method(:with)
    trusted_client = lambda do |**options|
      original_with.call(**options, ssl: options.fetch(:ssl, {}).merge(cert_store: trust))
    end
    prepared = ModelProviders::CodexAuthorization::Requests.user_code_request.with(
      url: "https://127.0.0.1:#{listener.addr[1]}/usercode", body: ""
    )
    HTTPX.stub(:with, trusted_client) do
      request = Thread.new do
        ModelProviders::CodexAuthorization::Transport.perform(prepared: prepared, deadline_at: Time.current + 5)
      end
      assert delivered.pop(timeout: 3), "the peer must finish the response"
      assert request.join(1), "the completed response must not wait for peer shutdown"
      assert_predicate request.value, :responded?
      assert_equal 200, request.value.status
      assert_equal "{}", request.value.body
    ensure
      release << true
      server.join(3)
      request&.join(6)
    end
  ensure
    listener&.close
    server&.kill
  end

  private

    def local_tls_context
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
      certificate.issuer = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 300
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = certificate
      extensions.issuer_certificate = certificate
      certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
      certificate.sign(key, OpenSSL::Digest::SHA256.new)
      OpenSSL::SSL::SSLContext.new.tap do |context|
        context.cert = certificate
        context.key = key
      end
    end
end
