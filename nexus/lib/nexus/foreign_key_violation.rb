module Nexus
  module ForeignKeyViolation
    # RESTRICT reports 23503 on PostgreSQL 17 and 23001 on PostgreSQL 18.
    # Match the expected constraint so an unrelated FK failure stays loud.
    def self.matches?(error, constraint:)
      case error.cause
      in PG::ForeignKeyViolation | PG::RestrictViolation => cause
        cause.result&.error_field(PG::PG_DIAG_CONSTRAINT_NAME) == constraint
      else
        false
      end
    end
  end
end
