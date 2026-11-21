module Nexus
  # Only authored schemas and route metadata enter this document. In particular,
  # model classes are never passed to OasRails' Active Record schema inference.
  module Openapi
    class << self
      def document
        if Rails.env.production?
          @document ||= build
        else
          build
        end
      end

      def build
        OasRails.build(config: configuration).tap do |document|
          # OasCore omits empty arrays, but an explicitly public operation
          # still needs a security declaration for OpenAPI consumers.
          document.fetch(:paths).each_value do |operations|
            operations.each_value { |operation| operation[:security] ||= [] }
          end
        end
      end

      private

        def configuration
          OasRails.config.tap do |config|
            config.api_path = "/"
            config.include_mode = :explicit
            config.route_extractor = Routes
            config.source_oas_path = "config/openapi/components.json"
            config.autodiscover_request_body = false
            config.autodiscover_responses = false
            config.set_default_responses = false
            config.authenticate_all_routes_by_default = false
            config.info.title = "Nexus HTTP API"
            config.info.version = "v1"
            config.info.description = "Member, executor and Human Platform APIs. Each operation declares its credential plane."
            config.prefix_path = ""
            config.security_schemas = {
              MemberBearer: { type: "http", scheme: "bearer", description: "Member-plane credential. Workspace and Conversation standing still apply." },
              ExecutorBearer: { type: "http", scheme: "bearer", description: "Executor-transport credential bound to one executor address." },
              PlatformBearer: { type: "http", scheme: "bearer", description: "Human Platform access token or API Session bearer. Admin operations additionally require a live owner/admin." },
              BrowserSession: { type: "apiKey", in: "cookie", name: "session_id", description: "Signed Human browser Session, accepted only on safe Platform reads. An Authorization header takes precedence." },
            }
            prefix = Rails.application.config.relative_url_root.to_s.delete_suffix("/")
            config.servers = [{ url: "#{prefix}/", description: "This Nexus installation" }]
          end
        end
    end
  end
end
