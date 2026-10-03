module ModelRunner
  # The runner's boot shim between `config/application` and `config/environment`:
  # its own log file (a reactor's per-stream lines do not belong in the web log)
  # with a console broadcast. `isolation_level = :fiber` is global (config/application.rb).
  # A file the environment names for this process (`RAILS_LOG_FILE`,
  # config/environments/development.rb) stands as configured: the e2e harness
  # gives each world's runner its own whole file under the world's run root.
  module RailsBoot
    LOG_FILE_SIZE = 100 * 1024 * 1024
    private_constant :LOG_FILE_SIZE

    def self.install(application)
      return if application.instance_variable_defined?(:@model_runner_rails_boot_installed)

      application.instance_variable_set(:@model_runner_rails_boot_installed, true)

      application.initializer(
        "model_runner.configure_logger",
        after: :load_environment_hook,
        before: :initialize_logger
      ) do |app|
        next if ENV["RAILS_LOG_FILE"].present?

        app.config.paths["log"] = app.root.join("log", "model_runner.#{Rails.env}.log").to_s
        app.config.logger = nil
        app.config.log_file_size ||= LOG_FILE_SIZE
      end

      application.initializer(
        "model_runner.broadcast_logger",
        after: :initialize_logger,
        before: :initialize_error_reporter
      ) do
        next if ActiveSupport::Logger.logger_outputs_to?(Rails.logger, $stderr, $stdout)

        console = ActiveSupport::Logger.new($stdout)
        console.formatter = Rails.logger.formatter
        console.level = Rails.logger.level
        Rails.logger.broadcast_to(console)
      end
    end
  end
end
