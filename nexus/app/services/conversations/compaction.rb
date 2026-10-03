module Conversations
  # A FAT KERNEL COMPACTS: one arm over two hosts — a round of a
  # loop-backed turn mid-turn, a `compaction_summary` turn between turns —
  # armed when a request will not go, never at a threshold.
  module Compaction
    # The frame the KERNEL puts before every summary a model reads, at the
    # three sites a summary stands in for history: the summariser is asked
    # for pointers, and the kernel states the rule, because a flash-tier
    # model's compliance is the thing under repair (the fifty-two invented
    # first lines of the long-session lane were written from a summary).
    REREAD_RULE = "This summary replaces earlier history and carries no data values: " \
      "re-read any file, output or result it mentions before you use it.".freeze
  end
end
