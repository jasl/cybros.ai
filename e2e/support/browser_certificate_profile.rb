require "sqlite3"
require "openssl"
require "tmpdir"
require "support/browser_actor"

module E2E
  # Prepare Chromium's own certificate-manager state before browser launch.
  # This profile is disposable; no platform trust or certificate checks change.
  module BrowserCertificateProfile
    def self.open(certificate)
      return yield :e2e_headless_chrome unless certificate

      Dir.mktmpdir("turn-tls-browser") do |directory|
        profile = File.join(directory, "Default")
        FileUtils.mkdir_p(profile)
        der = OpenSSL::X509::Certificate.new(File.read(certificate)).to_der
        SQLite3::Database.new(File.join(profile, "ServerCertificate")) do |database|
          database.execute("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
          database.execute("INSERT INTO meta VALUES ('version', '1'), ('last_compatible_version', '1')")
          database.execute("CREATE TABLE certificates(sha256hash_hex TEXT PRIMARY KEY, der_cert BLOB NOT NULL, trust_settings BLOB NOT NULL)")
          # CertificateMetadata.trust.trust_type = TRUSTED (3), protobuf encoding.
          database.execute("INSERT INTO certificates VALUES (?, ?, ?)", [
            OpenSSL::Digest::SHA256.hexdigest(der), SQLite3::Blob.new(der), SQLite3::Blob.new("\x0a\x02\x08\x03"),
          ])
        end
        driver = :e2e_turn_tls_chrome
        Capybara.register_driver(driver) { |app| BrowserActor.driver(app, profile: directory) }
        begin
          yield driver
        ensure
          # Release the captured temporary path without deprecated registry deletion.
          Capybara.register_driver(driver, &Capybara.drivers[:e2e_headless_chrome])
        end
      end
    end
  end
end
