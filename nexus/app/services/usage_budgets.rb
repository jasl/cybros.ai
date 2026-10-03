# The HTTP-neutral budget command namespace: open, adjust, and revoke.
# Shared coercion lives here; each command owns its authority, locking, and
# replay semantics.
module UsageBudgets
  # Exact nonnegative BigDecimal or nil, and never a value
  # numeric(38,18) cannot hold exactly: a rounded amount would
  # phantom-conflict every exact replay. Exact or refused.
  AMOUNT_SCALE = 18
  MAX_AMOUNT = BigDecimal("1e20")

  def self.exact_nonnegative(value)
    decimal =
      case value
      when BigDecimal then value
      when Integer, String then BigDecimal(value.to_s)
      else nil
      end
    return nil if decimal.nil? || decimal.negative?
    return nil if decimal >= MAX_AMOUNT || decimal != decimal.round(AMOUNT_SCALE)

    decimal
  rescue ArgumentError
    nil
  end

  # The ledger's own column bounds, refused as typed :invalid instead of
  # escaping as driver exceptions — in the COLUMN's own metric: varchar
  # counts characters, so both validators do too.
  OPERATION_KEY_MAX_LENGTH = 64
  REASON_MAX_LENGTH = 255

  # The settle namespace is the machine's: a caller-planted entry under a
  # receipt's key would silently swallow the charge.
  RESERVED_OPERATION_KEY_PREFIX = "settle:".freeze

  def self.valid_operation_key?(key)
    key.present? && key.to_s.length <= OPERATION_KEY_MAX_LENGTH &&
      !key.to_s.start_with?(RESERVED_OPERATION_KEY_PREFIX)
  end

  def self.valid_reason?(reason)
    reason.nil? || reason.to_s.length <= REASON_MAX_LENGTH
  end

  # At the column's own precision, so what a caller asked for, what is
  # stored and what a replay reads back are one value.
  COLUMN_TIME_PRECISION = 6

  def self.at_column_precision(instant)
    instant&.round(COLUMN_TIME_PRECISION)
  end
end
