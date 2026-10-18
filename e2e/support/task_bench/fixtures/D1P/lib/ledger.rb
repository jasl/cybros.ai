require_relative "posting"

class Ledger
  attr_reader :postings

  def initialize
    @postings = []
  end

  def post(posting)
    raise ArgumentError, "a posting's amount must not be zero" if posting.amount.zero?

    @postings << posting
    posting
  end
end
