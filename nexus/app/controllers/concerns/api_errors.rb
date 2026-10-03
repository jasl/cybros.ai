# The one JSON error boundary both API families share: leaf controllers
# raise, the rescue ladder renders { error: { code, message } }.
module APIErrors
  extend ActiveSupport::Concern
  include RateLimitedResponse

  # A present-but-malformed request value with a written 400 contract:
  # non-integer or out-of-range lock_version/limit, an unknown filter value,
  # an overlong Idempotency-Key.
  class ParameterInvalid < StandardError
    attr_reader :parameter

    def initialize(parameter)
      @parameter = parameter
      super("Invalid parameter: #{parameter}")
    end
  end

  included do
    rescue_from ModelCatalog::Unavailable, with: :render_catalog_unavailable
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid
    rescue_from ActionController::ParameterMissing, with: :render_parameter_missing
    rescue_from ActionDispatch::Http::Parameters::ParseError, with: :render_bad_request
    rescue_from ParameterInvalid, with: :render_parameter_invalid
  end

  private

    # A family code's status is not the caller's to choose: the shared codes
    # publish `status_by_code`, honoured here so no resource can disagree with
    # the contract. Every other code keeps its resource page's status.
    def render_error(code, message, status:)
      render json: { error: { code: code, message: message } },
        status: Nexus::FamilyErrors.status_for(code) || status
    end

    # THE ONE REFUSAL RENDERER: a domain refusal to the wire, read off the
    # family base's four tables — `REFUSAL_CODES` (a service's symbol whose
    # wire word differs; the symbol IS the code otherwise),
    # `REFUSAL_STATUSES` (wire code → status, the open vocabulary at
    # `REFUSAL_DEFAULT_STATUS`), `REFUSAL_MESSAGES` (the sentence a code
    # carries beyond `Refused: <code>`, `%{detail}` for the word it is
    # about) and `ABSENCE_REFUSALS` (concealed as the family's
    # `not_found`). A caller's own sentence wins; a family code keeps its
    # published status whatever the table says (`render_error`).
    def render_refusal(outcome, message = nil, detail: nil)
      family = self.class
      return render_not_found if family::ABSENCE_REFUSALS.include?(outcome)

      code = family::REFUSAL_CODES.fetch(outcome, outcome)
      status = family::REFUSAL_STATUSES.fetch(code, family::REFUSAL_DEFAULT_STATUS)
      message ||= format(family::REFUSAL_MESSAGES.fetch(code, "Refused: #{code}"), detail: detail)
      render_error(code.to_s, message, status: status)
    end

    def render_catalog_unavailable
      render_error(:model_plane_unavailable,
        "The model catalog is not available on this server", status: :service_unavailable)
    end

    # The shared bounded integer caster: missing is the caller's 400
    # parameter_missing; present-but-malformed, negative, or out-of-range
    # is 400 parameter_invalid.
    def bounded_integer(value, name, range:)
      raise ActionController::ParameterMissing.new(name) if value.nil?

      integer = begin
        Integer(value.to_s, 10)
      rescue ArgumentError
        raise APIErrors::ParameterInvalid, name
      end
      raise APIErrors::ParameterInvalid, name unless range.cover?(integer)

      integer
    end

    def render_unauthorized
      response.set_header("WWW-Authenticate", 'Bearer realm="Nexus"')
      render_error(:unauthorized, "Unauthorized", status: :unauthorized)
    end

    def render_not_found(_exception = nil)
      render_error(:not_found, "Not found", status: :not_found)
    end

    def render_record_invalid(exception)
      render_error(:validation_failed, exception.record.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end

    def render_parameter_missing(exception)
      render_error(:parameter_missing, "Missing parameter: #{exception.param}", status: :bad_request)
    end

    def render_parameter_invalid(exception)
      render_error(:parameter_invalid, exception.message, status: :bad_request)
    end

    def render_bad_request(_exception = nil)
      render_error(:bad_request, "Bad request", status: :bad_request)
    end

    def render_rate_limit_error
      render_error(:rate_limited, "Too many requests", status: :too_many_requests)
    end
end
