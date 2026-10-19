module Tasks
  # A question's field definition is captured with the await, never inferred
  # again from a model prompt or from a client's rendered controls.
  class AskField
    include StoreModel::Model

    TYPES = %w[string integer number boolean choice multichoice].freeze
    KEYS = %w[name label type required options].freeze
    MAX_FIELDS = 32
    MAX_OPTIONS = 64

    attribute :name
    attribute :label
    attribute :type
    attribute :required, default: false
    attribute :options

    validates :name, format: { with: /\A[a-zA-Z][a-zA-Z0-9_]{0,63}\z/ }
    validates :type, inclusion: { in: TYPES }
    validates :required, inclusion: { in: [true, false] }
    validate :strings_and_options

    class << self
      def refusal(fields)
        return nil if fields.nil?
        list = Array.try_convert(fields)
        return :invalid_ask_fields unless list && (1..MAX_FIELDS).cover?(list.length)
        return :invalid_ask_fields unless Nexus::SizeBounds.json_within?(:envelope_bound, fields)

        names = []
        list.each do |raw|
          value = Hash.try_convert(raw)
          return :invalid_ask_fields unless value && (value.keys - KEYS).empty?
          field = new(value)
          return :invalid_ask_fields unless field.valid?
          names << field.name
        end
        :invalid_ask_fields unless names.uniq == names
      rescue Nexus::CanonicalJson::UnsupportedValue
        :invalid_ask_fields
      end

      def answer_refusal(fields, answer)
        values = Hash.try_convert(answer)
        return :invalid_ask_answer unless values && (values.keys - fields.map(&:name)).empty?
        return :invalid_ask_answer unless fields.all? do |field|
          values.key?(field.name) ? field.answer_refusal(values.fetch(field.name)).nil? : !field.required
        end

        nil
      end
    end

    def answer_refusal(value)
      # JSON is a closed wire union. No coercion: "false" and "0" must
      # not become a person's boolean or numeric decision.
      accepted = case value
      when String
        type == "string" || (type == "choice" && options.include?(value))
      when Integer
        %w[integer number].include?(type)
      when Float
        type == "number" && value.finite?
      when true, false
        type == "boolean"
      when Array
        type == "multichoice" && value.uniq == value && (value - options).empty?
      when Hash, nil
        false
      else
        false
      end
      :invalid_ask_answer unless accepted
    end

    private

      def strings_and_options
        errors.add(:name, :invalid) unless String.try_convert(name)
        errors.add(:label, :invalid) unless String.try_convert(label)&.present?
        if %w[choice multichoice].include?(type)
          choices = Array.try_convert(options)
          unless choices && (1..MAX_OPTIONS).cover?(choices.length) &&
              choices.all? { |choice| String.try_convert(choice) } && choices.uniq == choices
            errors.add(:options, :invalid)
          end
        elsif !options.nil?
          errors.add(:options, :invalid)
        end
      end
  end
end
