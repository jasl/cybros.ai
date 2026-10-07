# The first-boot form object: carries the setup page into
# Account.create_with_owner and maps each founding record's errors back onto
# the form. No persistence, no authorization.
class Setup
  DEFAULT_ACCOUNT_NAME = "Nexus".freeze
  DEFAULT_COST_UNIT = "USD".freeze

  include ActiveModel::Model
  include ActiveModel::Attributes
  include ActiveModel::Attributes::Normalization

  attribute :account_name, :string, default: DEFAULT_ACCOUNT_NAME
  attribute :cost_unit, :string, default: DEFAULT_COST_UNIT
  attribute :display_name, :string
  attribute :email, :string
  attribute :password, :string
  attribute :password_confirmation, :string

  normalizes :cost_unit, with: ->(unit) { unit.to_s.strip.presence || DEFAULT_COST_UNIT }, apply_to_nil: true

  # Founds the installation and returns the Account, or nil with form errors.
  def establish
    Account.create_with_owner(
      account: { name: account_name.presence || DEFAULT_ACCOUNT_NAME, cost_unit: cost_unit },
      owner: {
        email: email,
        display_name: display_name,
        password: password,
        password_confirmation: password_confirmation,
      }
    )
  rescue ActiveRecord::RecordInvalid => e
    absorb_errors(e.record)
    nil
  end

  private

    def absorb_errors(record)
      record.errors.each do |error|
        errors.add(form_attribute_for(record, error.attribute), error.message)
      end
    end

    def form_attribute_for(record, attribute)
      case record
      in Account
        case attribute
        when :name then :account_name
        when :cost_unit then :cost_unit
        else :base
        end
      in Identity | User
        attribute_names.include?(attribute.to_s) ? attribute : :base
      else
        raise ArgumentError, "unsupported setup record: #{record.class.name}"
      end
    end
end
