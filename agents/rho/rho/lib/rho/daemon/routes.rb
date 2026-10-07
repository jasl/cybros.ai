require "openssl"

module Rho
  class Daemon
    # The registry behind the control surface: core's routes and every
    # extension's, one owner per [method, path]. A second claim is a load
    # error (the tool-name rule): load order must never displace `/status`.
    class Routes
      def initialize(routes:, context:, lineage:, bearer:, browser_login: nil)
        @routes = routes.each_with_object({}) { |route, table| claim(table, route) }
        @context = context
        @lineage = lineage
        @bearer = bearer
        @browser_login = browser_login
      end

      def table = @routes.transform_values { |route| guarded(route) }

      # Every route with its owner, for the test that asks who serves a path.
      def entries = @routes.values

      private

        def claim(table, route)
          key = [route.method, route.path]
          existing = table[key]
          if existing
            raise Rho::Runner::Extensions::RegistrationError,
              "#{route.extension} registers #{route.method} #{route.path}, already registered by " \
              "#{existing.extension}. Two extensions cannot serve one route — register a " \
              "different path and disable the other."
          end

          table[key] = route
        end

        # The bearer, the admission gate and the exception map, applied once
        # here so no handler carries a copy; an open door skips the first two.
        def guarded(route)
          lambda do |request|
            # Browser authorization can yield while settings replace this route.
            # Keep its selected owner alive through authorization and execution.
            owner = route.owner&.acquire
            if route.auth == :none && route.path == "/healthz"
              answer(route, request)
            else
              admitted do
                if route.auth == :none || authorized?(request)
                  answer(route, request)
                else
                  Refusal.unauthorized
                end
              end
            end
          rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
            Refusal.from_api_error(error)
          ensure
            owner&.release
          end
        end

        # Stop seals the gate first and waits for every admitted handler
        # before the lifetime home lock goes.
        def admitted
          admitted = @lineage.admit
          return Refusal.stopping unless admitted

          yield
        ensure
          @lineage.release if admitted
        end

        def answer(route, request)
          if (refusal = ingress_guard(route, request))
            return refusal
          end

          route.handler.call(request, @context)
        rescue ControlServer::MalformedBody => error
          Refusal.malformed(error.message)
        rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
          Refusal.from_api_error(error)
        end

        # A cooperative WebUI guard, not a credential or kernel permission.
        # The selected conversation accompanies run/task commands too. Read the
        # plugin's current binding at request time so a stale tab cannot edit it.
        def ingress_guard(route, request)
          return if %w[GET HEAD].include?(route.method) || %w[/stop /followers/attach].include?(route.path)

          public_id = Array(request.headers["x-rho-viewing-conversation"]).first.to_s
          return if public_id.empty?

          bindings = @context.conversation_bindings(public_id)
          return if bindings.empty?

          Refusal.new(status: 409, code: "ingress_bound",
            message: "This conversation is connected to #{bindings.map { |row| row.fetch("label") }.join(", ")}. Continue there, or use Stop.")
        end

        def authorized?(request)
          # Protocol::HTTP downcases header names, and returns a list for
          # repeated ones: `Authorization: a` twice must not concatenate into
          # something that happens to end with the real bearer.
          presented = Array(request.headers["authorization"]).first.to_s[/\ABearer (.+)\z/, 1]
          return false if presented.nil?

          # Constant-time: the announcement is 0600, so another local user cannot
          # read the bearer, and must not be able to feel it out either.
          OpenSSL.secure_compare(presented, @bearer) || !!@browser_login&.authorized?(request)
        end
    end
  end
end
