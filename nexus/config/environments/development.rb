require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  if Rails.root.join("tmp/email-dev.txt").exist?
    config.action_mailer.delivery_method = :letter_opener
    config.action_mailer.perform_deliveries = true
  else
    config.action_mailer.raise_delivery_errors = false
  end

  # Change to :null_store to avoid any caching.
  config.cache_store = :memory_store

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  # Make template changes take effect immediately.
  config.action_mailer.perform_caching = false

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

  # Local development without a canonical origin still mails itself links to
  # the dev server's own address.
  if config.action_mailer.default_url_options.blank?
    config.action_mailer.default_url_options = {
      host: "localhost",
      port: ENV.fetch("PORT", "3000").to_i,
    }
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # A PROCESS'S OWN RAILS LOG (`RAILS_LOG_FILE`): the e2e harness gives each
  # world's web, jobs and runner process one file under the world's run root,
  # so a red world's dump holds every line the world wrote. The checkout's
  # shared `log/development.log` rotates at 100 MiB (`load_defaults` for
  # local envs), and six processes over two worlds rotate it within minutes
  # — so the named file never rotates: a per-world file is whole.
  if ENV["RAILS_LOG_FILE"].present?
    config.paths["log"] = ENV["RAILS_LOG_FILE"]
    config.log_file_size = nil
  end

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # The N+1 detector: a lazy load that repeats on an association is logged,
  # never raised, and only in development (a test run raises on lazy loads).
  config.active_record.strict_loading_by_default = true
  config.active_record.strict_loading_mode = :n_plus_one_only
  config.active_record.action_on_strict_loading_violation = :log

  # Append comments with runtime information tags to SQL queries in logs.
  config.active_record.query_log_tags_enabled = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # Highlight code that triggered redirect in logs.
  config.action_dispatch.verbose_redirect_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Apply autocorrection by RuboCop to files generated by `bin/rails generate`.
  # config.generators.apply_rubocop_autocorrect_after_generate!
end
