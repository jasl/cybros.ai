module Rho
  module PresetExecution
    module_function

    # Both values are authored natural-root limits. Instance and role ceilings
    # narrow that selection; an empty authored list never inherits new roots.
    def limit_memory(authored, ceiling:)
      return ceiling if authored.nil?
      return authored if ceiling.nil?

      allowed = ceiling.fetch("bindings").to_h { |binding| [binding.fetch("source").fetch("scope"), binding.fetch("access")] }
      { "bindings" => authored.fetch("bindings").filter_map do |binding|
        access = allowed[binding.fetch("source").fetch("scope")]
        if access
          binding.merge("access" => (binding.fetch("access") == "read" || access == "read" ? "read" : "read_write"))
        end
      end }
    end
  end
end
