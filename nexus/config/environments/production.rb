require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Email provider Settings
  #
  # SMTP setting can be configured via environment variables.
  # The sender defaults in ApplicationMailer and may be overridden with
  # MAILER_FROM_ADDRESS.
  # For other configuration options, consult the Action Mailer documentation.
  if smtp_address = ENV["SMTP_ADDRESS"].presence
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: smtp_address,
      port: ENV.fetch("SMTP_PORT", ActiveModel::Type.lookup(:boolean).cast(ENV["SMTP_TLS"]) ? "465" : "587").to_i,
      domain: ENV.fetch("SMTP_DOMAIN", nil),
      user_name: ENV.fetch("SMTP_USERNAME", nil),
      password: ENV.fetch("SMTP_PASSWORD", nil),
      authentication: ENV["SMTP_AUTHENTICATION"].presence,
      tls: ActiveModel::Type.lookup(:boolean).cast(ENV["SMTP_TLS"]),
      openssl_verify_mode: ENV["SMTP_SSL_VERIFY_MODE"],
    }.compact
  end

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  if cdn_host = ENV["CDN_HOST"].presence
    config.asset_host = cdn_host
  end

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings.
  config.eager_load = true

  # In Rake tasks, the previous assignment is ignored, config.eager_load is set
  # from config.rake_eager_load.
  config.rake_eager_load = false

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Store uploaded files on the local file system (see config/storage.yml for
  # options). Nothing here couples to Disk any more: the OneShot files route
  # streams through `ActiveStorage::Streaming`, so another service is one
  # storage.yml line.
  config.active_storage.service = :local

  # The administrator-declared canonical origin for absolute URLs (`BASE_URL`).
  # This is trusted operator configuration: an http(s) origin with a host is
  # taken exactly as declared, anything else fails the boot, and best practice
  # lives in the deployment documentation. The port is carried
  # always, including 80/443: in a controller request Rails otherwise fills
  # an omitted default port from the untrusted request Host, while route
  # helpers normalize explicit default ports back out. Absolute links then
  # ignore the request Host entirely; deployments without a BASE_URL keep
  # using each request's own origin.
  if (base_url = ENV["BASE_URL"]).present?
    begin
      uri = URI.parse(base_url.strip)
      raise URI::InvalidURIError unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    rescue URI::Error
      raise "BASE_URL must use http or https and include a host, for example https://nexus.example.com", cause: nil
    end

    routes.default_url_options =
      { host: uri.host.downcase, protocol: uri.scheme.downcase, port: uri.port }
    config.action_mailer.default_url_options = routes.default_url_options.dup
  end

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = ActiveModel::Type.lookup(:boolean).cast(
    ENV.fetch("RAILS_ASSUME_SSL") { (routes.default_url_options[:protocol] == "https").to_s }
  )

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = ActiveModel::Type.lookup(:boolean).cast(
    ENV.fetch("RAILS_FORCE_SSL") { (routes.default_url_options[:protocol] == "https").to_s }
  )

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [:request_id]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default file-based cache store with a more robust alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [:id]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
