module SimpleInference
  module Protocols
    # The Responses and Chat Completions spellings. Model catalogs narrow
    # these values: modern models use options.ttl; older ones use retention.
    # No model-name inference and no implicit lifetime or breakpoint changes.
    module PromptCache
      def self.lower(options)
        ttl = options[:prompt_cache_ttl]
        rest = options.except(:prompt_cache_ttl)
        case ttl
        when nil then rest
        when "24h" then rest.merge(prompt_cache_retention: ttl)
        when "30m", "12h" then rest.merge(prompt_cache_options: { ttl: ttl })
        else
          raise SimpleInference::ValidationError, "unsupported prompt_cache_ttl: #{ttl.inspect}"
        end
      end
    end
  end
end
