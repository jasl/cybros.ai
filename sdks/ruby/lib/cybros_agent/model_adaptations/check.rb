module CybrosAgent
  module ModelAdaptations
    # THE REFUSAL VOCABULARY of one pack file: every rule below raises
    # `Invalid` naming the file and the YAML path, so a malformed row says
    # which line to fix rather than that something is wrong.
    class Check
      attr_reader :file

      def initialize(file)
        @file = file
      end

      def refuse(path, message)
        raise Invalid.new(file, path, message)
      end

      # A mapping whose keys are exactly `required` plus a subset of
      # `optional`; an unknown key is refused by name.
      def mapping(value, path, required:, optional: [])
        refuse(path, "expected a mapping, got #{value.class}") unless value.is_a?(Hash)
        unknown = value.keys - required - optional
        refuse(path, "unknown key #{unknown.first.inspect}") unless unknown.empty?
        missing = required - value.keys
        refuse(path, "missing key #{missing.first.inspect}") unless missing.empty?
        value
      end

      def string(value, path)
        refuse(path, "expected a non-empty string, got #{value.inspect}") unless value.is_a?(String) && !value.empty?
        value
      end

      def optional_string(value, path)
        value.nil? ? nil : string(value, path)
      end

      def boolean(value, path)
        refuse(path, "expected true or false, got #{value.inspect}") unless [true, false].include?(value)
        value
      end

      def array(value, path)
        refuse(path, "expected a list, got #{value.class}") unless value.is_a?(Array)
        value
      end

      # A list of non-empty strings with no repeat.
      def strings(value, path)
        array(value, path).each_with_index.map { |item, index| string(item, "#{path}[#{index}]") }
          .tap { |items| unique(items, path) }
      end

      def unique(items, path)
        repeated = items.find { |item| items.count(item) > 1 }
        refuse(path, "#{repeated.inspect} appears twice") unless repeated.nil?
        items
      end

      def one_of(value, path, allowed)
        refuse(path, "#{value.inspect} is not one of #{allowed.join(", ")}") unless allowed.include?(value)
        value
      end

      def subset(items, path, allowed)
        stranger = items.find { |item| !allowed.include?(item) }
        refuse(path, "#{stranger.inspect} is not one of #{allowed.join(", ")}") unless stranger.nil?
        items
      end

      def format(value)
        refuse("format", "expected #{FORMAT}, got #{value.inspect}") unless value == FORMAT
      end
    end
  end
end
