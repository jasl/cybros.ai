module Nexus
  # The family's shared error codes and the status each carries, published as
  # `contracts/nexus/v1/errors.json`: a caller may branch on the code alone.
  # Every other code is a resource's own open vocabulary. Read by the app, not only the contract.
  module FamilyErrors
    # Numeric, because this IS the published wire value and Rack's symbol
    # vocabulary is its own moving target — `:unprocessable_entity` is already
    # deprecated there while 422 is not going anywhere. The executor plane's
    # six refusals are family codes: a runner branches on the code alone, and
    # every one is a reachable conflict. `not_authorized` is NOT one — its
    # status differs by door.
    STATUS = {
      "already_claimed" => 409,
      "bad_request" => 400,
      "content_too_large" => 413,
      "idempotency_envelope_mismatch" => 409,
      "idempotency_key_required" => 400,
      "not_addressed_here" => 409,
      "not_claimable_kind" => 409,
      "not_eligible" => 409,
      "not_found" => 404,
      "parameter_invalid" => 400,
      "parameter_missing" => 400,
      "rate_limited" => 429,
      "stale_claim" => 409,
      "stale_object" => 409,
      "task_not_claimable" => 409,
      "unauthorized" => 401,
      "validation_failed" => 422,
    }.freeze

    # The status a family code must carry, or nil for a code the family does
    # not own. A caller passes its own intended status for anything else.
    def self.status_for(code) = STATUS[code.to_s]
  end
end
