module Ledger
  class Account
    KINDS = %w[asset liability income expense].freeze

    attr_reader :name, :kind

    def initialize(name, kind)
      raise Error, "unknown account kind #{kind.inspect}" unless KINDS.include?(kind)

      @name = name
      @kind = kind
    end

    def to_s = name
  end
end
