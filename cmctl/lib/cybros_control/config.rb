module CybrosControl
  # The CLI owns persistence. The SDK only carries the API session to Nexus.
  # Passwords and provider keys never enter this document.
  class Config
    Credentials = Data.define(:base_url, :token) do
      def inspect = "#<CybrosControl::Config::Credentials [REDACTED]>"
    end

    def self.base_url(value)
      uri = URI.parse(value.to_s)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? &&
          !uri.userinfo && !uri.query && !uri.fragment
        raise UsageError, "Nexus URL must be HTTP(S), without credentials, query or fragment"
      end

      uri.to_s.chomp("/")
    rescue URI::InvalidURIError
      raise UsageError, "Invalid Nexus URL"
    end

    def initialize(home:)
      @home = File.expand_path(home)
      @path = File.join(@home, "session.json")
    end

    def present? = File.exist?(@path)

    def read
      fields = JSON.parse(File.read(@path)).to_h
      token = fields.fetch("token").to_s
      raise Error, "Invalid saved session; log in again" if token.empty?

      Credentials.new(base_url: self.class.base_url(fields.fetch("base_url")), token: token)
    rescue Errno::ENOENT
      raise Error, "Not logged in; run cmctl login"
    rescue JSON::ParserError, TypeError, NoMethodError, KeyError, UsageError
      raise Error, "Invalid saved session; remove session.json and log in again"
    end

    def write(base_url:, token:)
      FileUtils.mkdir_p(@home, mode: 0o700)
      File.chmod(0o700, @home)
      Tempfile.create(["session-", ".json"], @home) do |file|
        file.chmod(0o600)
        file.write(JSON.generate(base_url: base_url, token: token))
        file.write("\n")
        file.flush
        File.rename(file.path, @path)
      end
    end

    def delete
      File.unlink(@path)
    rescue Errno::ENOENT
      nil
    end

    def inspect = "#<CybrosControl::Config [REDACTED]>"
  end
end
