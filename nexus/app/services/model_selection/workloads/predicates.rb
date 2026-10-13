module ModelSelection
  module Workloads
    # The value-shape questions every aspect asks, in one place so a second
    # copy cannot become a second answer.
    module Predicates
      module_function

      def supported_number?(value)
        integer = Integer(value, exception: false)
        numeric = integer if !integer.nil? && value.eql?(integer)
        if numeric.nil?
          float = Float(value, exception: false)
          numeric = float if !float.nil? && value.eql?(float)
        end
        return false if numeric.nil?

        Nexus::CanonicalJson.normalize(value)
        true
      rescue ArgumentError, Nexus::CanonicalJson::UnsupportedValue
        false
      end

      def matches_integer?(value)
        integer = Integer(value, exception: false)
        !integer.nil? && value.eql?(integer)
      end

      def present_string?(value)
        String.try_convert(value)&.strip&.present? || false
      end

      def symbol_keyed_hash?(value)
        attributes = Hash.try_convert(value)
        attributes && attributes.keys.all? { |key| key.to_s.to_sym.equal?(key) }
      end
    end
  end
end
