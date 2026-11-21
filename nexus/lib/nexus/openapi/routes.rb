module Nexus
  module Openapi
    # OasRails' extension point also handles shared controller concerns: their
    # action comments describe the shape, while the concrete controller's class
    # comment declares its own credential plane. Path tags on a shared action
    # are narrowed to the route that actually uses that action.
    class Routes < OasRails::Extractors::RouteExtractor
      class << self
        def host_routes(config:)
          clear_cache(config: config) unless Rails.env.production?
          super.map do |route|
            controller = "#{route.controller.camelize}Controller".constantize
            file, line = Object.const_source_location(controller.name)
            comment = File.readlines(file).take(line - 1).reverse
              .take_while { |text| text.lstrip.start_with?("#") || text.strip.empty? }
              .reverse.map { |text| text.sub(/^\s*# ?/, "") }.join
            class_tags = YARD::Docstring.parser.parse(comment).to_docstring.tags
            route.tags = route.tags + class_tags
            route.tags = route.tags.reject do |tag|
              tag.tag_name == "parameter" && tag.location == "path" && !route.path_params.include?(tag.name)
            end
            if route.tags(:auth).empty? && route.tags(:no_auth).empty?
              raise "#{route.controller}##{route.method_name} needs @auth or @no_auth"
            end
            # Platform cookies authenticate safe reads only; writes require
            # the declared bearer, just as the Platform base enforces.
            unless route.verb == "GET" || route.verb == "HEAD"
              route.tags(:auth).each { |tag| tag.types -= ["BrowserSession"] }
            end
            route
          end
        end
      end
    end
  end
end
