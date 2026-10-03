module CybrosControl
  class Setup
    module Authorization
      private

        def configure_authorization(context)
          authorization = context.authorization
          current = authorization.fetch
          if current.state == "authorized"
            choice = @prompt.choose("This subscription is already connected.",
              choices: ["Keep existing authorization", "Sign in again", "Clear authorization"])
            case choice
            when 0 then return
            when 1 then session = authorization.start(restart: true)
            when 2
              if @prompt.confirm("Clear this provider's authorization?", default: false)
                authorization.clear
                @prompt.say("Authorization cleared.")
              end
              return
            else raise Error, "Invalid authorization choice"
            end
          else
            session = resume_authorization(authorization, current)
            return unless session
          end
          await_authorization(authorization, session)
        end

        def resume_authorization(authorization, current)
          session = current.session
          if session && session.state == "pending" && !session.owned_by_current_user
            @prompt.say("Another administrator has started a login for this provider.")
            return unless @prompt.confirm("Replace that login and start your own?", default: false)

            return authorization.start(restart: true)
          end
          return session if session && session.state == "pending"

          if session && !@prompt.confirm("Start a new provider login? (previous: #{session.state})")
            return
          end
          authorization.start
        end

        def await_authorization(authorization, session)
          @prompt.say("Waiting for provider authorization. Ctrl-C keeps completed settings; rerun setup to resume.")
          deadline = @clock.call + 900
          displayed_code = nil
          pending = authorization.session(session.public_id)
          # The server owns OAuth progress; this bounded wait only reads it.
          loop do
            if session.user_code && session.user_code != displayed_code
              @prompt.say("Open in a browser: #{session.verification_uri}")
              @prompt.say("Enter code: #{session.user_code}")
              displayed_code = session.user_code
            end
            latest = pending.fetch
            if latest.state == "completed" && latest.outcome == "authorized"
              @prompt.say("Subscription connected.")
              return
            end
            unless latest.state == "pending"
              raise Error, "Provider login ended: #{latest.outcome || latest.state}. Rerun setup to try again."
            end
            if @clock.call >= deadline
              raise Error, "Still waiting for authorization. Rerun setup to resume the recorded login."
            end
            session = latest
            @sleeper.call(2)
          end
        end
    end
  end
end
