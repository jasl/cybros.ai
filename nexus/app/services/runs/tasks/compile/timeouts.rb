module Runs::Tasks::Compile::Timeouts
  MAX_TIMEOUT_MS = 7.days.in_milliseconds

  private

  # Only the member author holds the resolution token needed to advance an
  # indefinite coordination wait. Model questions and tool work stay finite.
  def compile_ask_timeout(step, path, member_authored:)
    unless [nil, true, false].include?(step.indefinite) &&
        (!step.indefinite || (member_authored && step.timeout_ms.nil?))
      refuse("invalid_indefinite", "#{path}.indefinite")
      return :error
    end

    timeout = compile_timeout(step.timeout_ms, path)
    return :error if timeout == :error

    (timeout || ::Tasks::AwaitTask::DEFAULT_TIMEOUT_MS) unless step.indefinite
  end

  def compile_timeout(value, path)
    return nil if value.nil?

    case value
    when Integer
      return value if value.positive? && value <= MAX_TIMEOUT_MS
    else nil
    end
    refuse("invalid_timeout_ms", "#{path}.timeout_ms")
    :error
  end
end
