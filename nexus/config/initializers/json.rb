# The agent API's timestamps are whole-second ISO 8601 UTC ("2026-09-05T12:00:00Z"),
# with process-global precision: every
# Time the JSON encoder meets renders this way, so presenters hand it raw
# values and never call iso8601 themselves.
ActiveSupport::JSON::Encoding.time_precision = 0
