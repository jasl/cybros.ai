# The ONE boolean cast for wire parameters: Rails' own casting, and a
# missing value stays nil — a form-encoded empty string must never become
# NULL against a NOT NULL column.
module BooleanParameter
  BOOLEAN = ActiveModel::Type::Boolean.new

  private

    def cast_boolean(value)
      value.nil? ? nil : BOOLEAN.cast(value)
    end
end
