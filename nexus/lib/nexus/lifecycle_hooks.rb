module Nexus
  # A profile names executor tools, not executable code or an inbound URL.
  # Execution and recovery use the ordinary task inbox and park deadline.
  module LifecycleHooks
    EVENTS = %w[turn_start pre_compact post_compact stop].freeze
    MAX_TIMEOUT_MS = 5.minutes.in_milliseconds
    MAX_CONTINUATIONS = 20
    MAX_FEEDBACK_BYTES = 16.kilobytes

    def self.well_formed?(value)
      hooks = Hash.try_convert(value)
      return false if hooks.nil? || (hooks.keys - EVENTS).any?

      hooks.all? do |event, value|
        hook = Hash.try_convert(value)
        next false if hook.nil?

        tool = String.try_convert(hook["tool"])
        timeout = Integer.try_convert(hook["timeout_ms"])
        allowed = %w[tool timeout_ms] + (event == "stop" ? ["max_continuations"] : [])
        valid = (hook.keys - allowed).empty? && tool.present? && tool.bytesize <= 128 &&
          !tool.include?("\u0000") && !Nexus::ToolRegistry.kernel_name?(tool) &&
          timeout == hook["timeout_ms"] && timeout.in?(1..MAX_TIMEOUT_MS)
        continuations = Integer.try_convert(hook["max_continuations"])
        valid && (event != "stop" ||
          (continuations == hook["max_continuations"] && continuations.in?(0..MAX_CONTINUATIONS)))
      end
    end

    # Only an explicitly kernel-authored hook interprets this protocol.
    # Ordinary tool structured output remains opaque.
    def self.result_refusal(event, value)
      result = Hash.try_convert(value)
      return :invalid_hook_result if result.nil? || (result.keys - %w[continue feedback]).any?
      return :invalid_hook_result unless [true, false].include?(result["continue"])
      return :invalid_hook_result if event != "stop" && result["continue"]

      feedback = result["feedback"]
      unless feedback.nil?
        text = String.try_convert(feedback)
        return :invalid_hook_result if text.nil? || text.bytesize > MAX_FEEDBACK_BYTES || text.include?("\u0000")
      end
      return :invalid_hook_result if result["continue"] && feedback.blank?

      nil
    end
  end
end
