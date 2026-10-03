# Every Rails.error report becomes the one house log line. Rails registers
# no logging subscriber of its own in any environment (railties
# bootstrap.rb only sets Rails.error.logger, which reports subscriber
# failures), so this is the log path everywhere, production included.
module Nexus
  class ErrorReportLine
    LEVELS = { error: :error, warning: :warn, info: :info }.freeze
    FRAMES = 5

    def report(error, handled:, severity:, context:, source:)
      fields = ["event=#{context.fetch(:event) { source }}"]
      fields.concat(context.except(:event, :rails, :job, :controller).map { |key, value| "#{key}=#{value}" })
      fields << "error_class=#{error.class.name}"
      fields << "error_message=#{error.message}"
      fields << "backtrace=#{Array(error.backtrace).first(FRAMES).join(" | ")}"
      Rails.logger.public_send(LEVELS.fetch(severity), fields.join(" "))
    end
  end
end

Rails.error.subscribe(Nexus::ErrorReportLine.new)
