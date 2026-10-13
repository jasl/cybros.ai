module UsageRecords
  # The one public usage shape both surfaces project through.
  # `cost_complete` keeps D24b honest: unmetered and unanswered are not
  # complete, exact zero is.
  class PublicUsage
    def self.render(receipt)
      return nil if receipt.nil?

      input = receipt.input_tokens.to_i
      cache_read = [receipt.cache_read_tokens.to_i, input].min
      {
        "usage_record_public_id" => receipt.public_id,
        "input_tokens" => receipt.input_tokens,
        "cache_read_tokens" => receipt.cache_read_tokens,
        "uncached_input_tokens" => receipt.input_tokens && (input - cache_read),
        "cache_creation_tokens" => receipt.cache_creation_tokens,
        "cache_hit_rate" => UsageRecord.cache_hit_rate(input, cache_read),
        "output_tokens" => receipt.output_tokens,
        "reasoning_tokens" => receipt.reasoning_tokens,
        "total_tokens" => receipt.total_tokens,
        "cost_amount" => receipt.cost_amount&.to_s("F"),
        "cost_unit" => receipt.cost_unit,
        "cost_complete" => !receipt.cost_amount.nil?,
      }.compact
    end

    def self.timing(receipt)
      return nil if receipt.nil?

      {
        "duration_ms" => receipt.duration_ms,
        "time_to_first_token_ms" => receipt.time_to_first_token_ms,
      }.compact.presence
    end
  end
end
