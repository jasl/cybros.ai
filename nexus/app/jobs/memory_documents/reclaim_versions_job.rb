module MemoryDocuments
  # Level-triggered and bounded, like every other reaper on this floor: a
  # pass that finds more work asks for another rather than draining the
  # table inside one invocation.
  class ReclaimVersionsJob < ApplicationJob
    queue_as :default

    def perform(after_id = 0)
      result = ReclaimVersions.call(after_id: after_id)
      ReclaimVersionsJob.perform_later(result.cursor) if result.more?
    end
  end
end
