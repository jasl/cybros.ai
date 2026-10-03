require "json"
require "net/http"
require "uri"
require_relative "secret_hygiene"

module E2E
  # Raw Platform requests for permission tests and the removal command that
  # the SDK intentionally omits. Operator product flows use PlatformClient
  # or cmctl; this helper lets a denied credential reach the actual HTTP boundary.
  class PlatformHttp
    Response = Data.define(:status, :body)

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30

    def initialize(base_url)
      @base_url = base_url
    end

    # One JSON request, returning the status and parsed body without judging
    # them — the lane owns every assertion, including the negative ones.
    # Diagnostics never carry the Authorization value.
    def post(path, body: nil, bearer: nil)
      send_json(Net::HTTP::Post, path, body: body, bearer: bearer)
    end

    # Read-only reports that the thin operator SDK does not wrap.
    def get(path, bearer: nil)
      send_json(Net::HTTP::Get, path, body: nil, bearer: bearer)
    end

    # The command verb for cost-unit and provider-lane permission journeys.
    def put(path, body: nil, bearer: nil)
      send_json(Net::HTTP::Put, path, body: body, bearer: bearer)
    end

    private

    def send_json(verb, path, body:, bearer:)
      uri = URI.join(@base_url, path)
      request = verb.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{SecretHygiene.register(bearer)}" if bearer
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      response = Net::HTTP.start(
        uri.host, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }
      status = Integer(response.code, 10)
      Response.new(status:, body: parse(response, status:))
    rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError => error
      raise "Platform request #{verb.name.split("::").last.upcase} #{path} failed: " \
        "#{error.class}: #{SecretHygiene.redact(error.message)}"
    end

    # Defined Platform responses speak JSON. Unhandled application and
    # intermediary failures may be text or empty, so callers classify 5xx by
    # status while retaining any raw diagnostic body.
    def parse(response, status:)
      raw = response.body
      if raw.nil? || raw.empty?
        return nil if status.between?(500, 599)

        raise_non_json_response(status, raw)
      end

      JSON.parse(raw)
    rescue JSON::ParserError
      return raw if status.between?(500, 599)

      raise_non_json_response(status, raw)
    end

    def raise_non_json_response(status, raw)
      raise "Platform response was not JSON (status #{status}): " \
        "#{SecretHygiene.redact(raw.to_s.byteslice(0, 200))}"
    end
  end
end
