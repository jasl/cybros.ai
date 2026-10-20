require "openssl"
require "securerandom"

module E2E
  # Ephemeral test material; never installed in the host trust store.
  TurnCertificate = Data.define(:certificate, :key) do
    def self.write(directory, address:)
      key = OpenSSL::PKey::EC.generate("prime256v1")
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = SecureRandom.random_number(2**128)
      certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=TURN fixture")
      certificate.public_key = key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 3600
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = extensions.issuer_certificate = certificate
      certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      certificate.add_extension(extensions.create_extension("keyUsage", "digitalSignature,keyCertSign", true))
      certificate.add_extension(extensions.create_extension("subjectAltName", "IP:#{address}"))
      certificate.sign(key, OpenSSL::Digest.new("SHA256"))
      cert_path = File.join(directory, "turn-ca.pem")
      key_path = File.join(directory, "turn-key.pem")
      File.write(cert_path, certificate.to_pem)
      File.write(key_path, key.to_pem, perm: 0o600)
      new(certificate: cert_path, key: key_path)
    end
  end
end
