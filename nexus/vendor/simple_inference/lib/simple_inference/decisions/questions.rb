module SimpleInference
  module Decisions
    # The common question grammar. Its names identify answers independently of
    # provider ordering; score levels always use their zero-based positions.
    Questions = Data.define(:entries) do
      Option = Data.define(:value, :description) do
        def self.from_h(value)
          attributes = Internal::Keys.shallow_stringify(value)
          new(value: attributes.fetch("value"), description: attributes.fetch("description", "").to_s)
        end
      end

      Level = Data.define(:label, :description) do
        def self.from_h(value)
          attributes = Internal::Keys.shallow_stringify(value)
          new(label: attributes.fetch("label").to_s, description: attributes.fetch("description", "").to_s)
        end
      end

      Question = Data.define(:name, :type, :instructions, :choices, :levels) do
        def self.from_h(value)
          attributes = Internal::Keys.shallow_stringify(value)
          type = attributes.fetch("type").to_s
          new(name: attributes.fetch("name").to_s, type: type,
            instructions: attributes.fetch("instructions").to_s,
            choices: type == "choice" ? attributes.fetch("choices").map { |entry| Option.from_h(entry) } : nil,
            levels: type == "score" ? attributes.fetch("levels").map { |entry| Level.from_h(entry) } : nil)
        end

        def to_h
          { "name" => name, "type" => type, "instructions" => instructions,
            "choices" => choices&.map { |entry| entry.to_h.transform_keys(&:to_s) },
            "levels" => levels&.map { |entry| entry.to_h.transform_keys(&:to_s) } }.compact
        end
      end

      def self.from_array(value)
        new(entries: value.map { |entry| Question.from_h(entry) })
      rescue KeyError, NoMethodError, TypeError => error
        raise SimpleInference::ValidationError, "invalid decision questions", cause: error
      end

      def initialize(entries:)
        unless (1..400).cover?(entries.length) && entries.map(&:name).uniq.length == entries.length
          raise SimpleInference::ValidationError, "questions must contain 1..400 uniquely named questions"
        end
        entries.each { |question| validate_question(question) }
        super(entries: entries.freeze)
      end

      def to_a = entries.map(&:to_h)

      private

      def validate_question(question)
        if question.name.strip.empty? || question.instructions.strip.empty?
          raise SimpleInference::ValidationError, "question name and instructions are required"
        end
        case question.type
        when "predicate"
          nil
        when "choice"
          values = question.choices.map(&:value)
          unless values.length >= 2 && values.uniq.length == values.length
            raise SimpleInference::ValidationError, "choice requires at least two distinct values"
          end
          values.each do |value|
            next if value == true || value == false

            text = String(value)
            unless value == text && !text.empty?
              raise SimpleInference::ValidationError, "choice values must be nonempty strings or booleans"
            end
          end
        when "score"
          labels = question.levels.map(&:label)
          unless (2..10).cover?(labels.length) && labels.uniq.length == labels.length && labels.none?(&:empty?)
            raise SimpleInference::ValidationError, "score requires 2..10 distinct named levels"
          end
        else
          raise SimpleInference::CapabilityError, "unsupported decision question type: #{question.type}"
        end
      end
    end
  end
end
