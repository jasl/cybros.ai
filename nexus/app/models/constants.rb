# Shared value constraints stay independent of model loading: routes and the
# boot-time catalog compiler need them before Active Record initializes.
module Constants
  COST_UNIT_MAX_LENGTH = 64

  HANDLE_MAX_LENGTH = 32
  # Routing forbids anchors; validation uses the same grammar anchored below.
  HANDLE_SEGMENT = /[a-z0-9][a-z0-9_-]{1,31}/
  HANDLE_FORMAT = /\A#{HANDLE_SEGMENT}\z/

  # Reject malformed addresses before querying UUID columns.
  PUBLIC_ID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
end
