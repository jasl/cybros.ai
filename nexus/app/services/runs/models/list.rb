module Runs
  module Models
    class List
      DEFAULT_LIMIT = 20
      MAX_LIMIT = 100

      def self.call(node:)
        return :not_running unless node.status == "running"

        input = node.tool_input
        query = String.try_convert(input.fetch("query", ""))
        raw_limit = input.fetch("limit", DEFAULT_LIMIT)
        raw_offset = input.fetch("offset", 0)
        limit = Integer.try_convert(raw_limit)
        offset = Integer.try_convert(raw_offset)
        unless query && limit && limit == raw_limit && (1..MAX_LIMIT).cover?(limit) &&
            offset && offset == raw_offset && offset >= 0 && (input.keys - %w[query limit offset]).empty?
          return KernelTool.settle(node,
            "parameter_invalid: query must be text, limit an integer from 1 to 100, and offset a nonnegative integer.",
            title: "available models", is_error: true)
        end

        account = node.run.account
        catalog = ModelSelection::Resolver.effective_catalog(account, ModelCatalog.current)
        query = query.strip.downcase
        models = ModelCatalog::Discovery.index(account: account, catalog: catalog).select do |model|
          model.fetch(:available) && [model.fetch(:ref), model.fetch(:provider), model[:model_identity],
            catalog.models.fetch(model.fetch(:ref))["model_id"]].compact.any? { |word| word.downcase.include?(query) }
        end
        page = offset < models.length ? models.slice(offset, limit) : []
        result = {
          "models" => page.map { |model| model.slice(:ref, :provider, :model_identity, :capabilities, :pricing) },
          "total" => models.length,
          "offset" => offset,
          "next_offset" => offset + page.length < models.length ? offset + page.length : nil,
        }
        KernelTool.settle(node, result.to_json, title: "available models")
      end
    end
  end
end
