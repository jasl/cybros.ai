require "monitor"
require "securerandom"
require_relative "browser_actor"
require_relative "secret_hygiene"
require_relative "session_sign_in_budget"

module E2E
  # The frozen Workspace-round actor topology on the shared Account, provisioned through existing
  # public HTML only: the founding owner signs up through /setup (or signs back in), direct-creates
  # each non-owner Human in the admin console with a temporary password, and each Human completes
  # the public forced-password ceremony and mints its own member token through Settings. There is no
  # JSON user-create, no fixture/database mutation, and no test-only backdoor. Temporary passwords
  # and revealed tokens are public synthetic test inputs; each is registered for best-effort
  # diagnostic redaction, and the browser leaves every reveal page before the ceremony returns.
  class ActorProvisioning
    OWNER_EMAIL = "owner@e2e.test".freeze
    OWNER_PASSWORD = "e2e password strong".freeze
    OWNER_DISPLAY_NAME = "E2E Owner".freeze
    ROLE_NAMES = {
      shared_human: "E2E Shared Human",
      lifecycle_source: "E2E Lifecycle Source",
      lifecycle_recipient: "E2E Transfer Recipient",
      removal_source: "E2E Removal Source",
      removal_recipient: "E2E Removal Recipient",
      rho_steward: "E2E Rho Steward",
      override_steward: "E2E Override Steward",
    }.freeze

    Speaker = Data.define(:role, :display_name, :email, :password, :public_id, :member_token)

    @worlds = {}
    @monitor = Monitor.new

    class << self
      # One world per booted Nexus: a single process runs every lane against
      # one shared server, so the topology is provisioned once and lanes
      # share the same Humans.
      def world(base_url)
        @monitor.synchronize do
          @worlds[base_url] ||= begin
            world = new(base_url)
            Minitest.after_run { world.close }
            world
          end
        end
      end
    end

    def initialize(base_url)
      @base_url = base_url
      @speakers = {}
      @owner_public_id = nil
      @owner_browser = nil
    end

    def close
      @owner_browser&.close
      @owner_browser = nil
    end

    def owner_email
      OWNER_EMAIL
    end

    def owner_password
      OWNER_PASSWORD
    end

    # The founding owner's User public id, read from the public admin console
    # URL — the show route is addressed by it.
    def owner_public_id
      @owner_public_id ||= with_owner_browser do |actor|
        find_member_public_id(actor, OWNER_DISPLAY_NAME)
      end
    end

    # THE HUMAN THE WORKLOAD LANES RUN AS, shared because none of them cares
    # what else it owns: a turn is a statement about one InferenceRequest.
    #
    # A LANE THAT MAKES A STATEMENT ABOUT EVERYTHING THIS HUMAN OWNS — an
    # empty list, a removal the transfer-first guard may refuse — MUST NOT
    # USE IT. Lanes run in a shuffled order in one process, so "nobody has
    # created a Workspace yet" is never a fact about a shared actor; it was
    # exactly that assumption, twice, that made two Workspace lanes fail on
    # whichever run put them last.
    def shared_human
      actor(:shared_human)
    end

    # The lifecycle lane's own pair. Its first assertion is that a freshly
    # provisioned Human owns nothing, which is only true of a Human no other
    # lane touches.
    def lifecycle_pair
      [actor(:lifecycle_source), actor(:lifecycle_recipient)]
    end

    # The removal lane's own pair, and the reason it is a pair of its own:
    # the lane ENDS WITH BOTH HUMANS REMOVED. Sharing them deleted speakers
    # other lanes were still holding credentials for, and inherited whatever
    # Workspaces those lanes had left live — which the transfer-first guard
    # then refused the removal over.
    def removal_pair
      [actor(:removal_source), actor(:removal_recipient)]
    end

    # The rho steward Human keeps these journeys' owned resources together;
    # each rho home supplies its own Account-unique instance identifier.
    def rho_steward
      actor(:rho_steward)
    end

    # THE OVERRIDE LANE'S OWN STEWARD: a rho paired under a Human adopts that Human's dedicated
    # workspace, one row per steward, so a lane that PUTs `tool_provider_overrides` on it re-routes
    # every sibling lane's memory tools while the override stands — and every world holds a rho file
    # on the shared steward. A private steward gives the override lane a dedicated workspace nobody
    # else addresses through, so the race is gone by construction rather than by a rule.
    def override_steward
      actor(:override_steward)
    end

    # The owner's browser session persists for the world's lifetime: the ceremonies it drives are
    # sequential, and one durable cookie session spends one grant of the shared sign-in budget
    # instead of one per ceremony. PUBLIC for the one grant only an owner can make — an ACCOUNT-WIDE
    # machine registration (a tools provider must serve another Human's agent) — beside the member
    # reads above.
    def with_owner_browser
      yield owner_browser
    end

    # The same browser, for a journey that drives the owner's console
    # itself (rho_daemon's ceremonies and profile pages): one founding or
    # sign-in per world, never one per test.
    def owner_browser
      @owner_browser ||= begin
        actor = BrowserActor.new(@base_url)
        found_or_sign_in_owner(actor)
        actor
      end
    end

    private

    # A FORM MUST HOLD WHAT WE TYPED BEFORE IT IS SUBMITTED.
    #
    # Chrome runs here with `--allow-pre-commit-input`, which lets a keystroke
    # land in a document that has not committed yet — so a fill can go to a
    # page that is about to be replaced, and the submit that follows carries
    # EMPTY fields. The server answers a validation error, and the step then
    # waits for a confirmation that was never coming. Reading the values back
    # is the deterministic condition for "this form is the one I filled", and
    # it is the Capybara primitive for exactly that question.
    #
    # All fills first, then all reads: a document replaced during any of them
    # is caught, not just one replaced during the last.
    def fill_form!(page, values)
      values.each { |field, value| page.fill_in(field, with: value) }
      values.each_key do |field|
        next if page.has_field?(field, with: values.fetch(field))

        raise "the #{field.inspect} field did not hold what was typed — #{page_state(page)}"
      end
    end

    # THE ONLY ACCOUNT THESE FAILURES CAN EVER GIVE.
    #
    # Every ceremony step waits for the page its submit should have produced,
    # and a step that did not get one used to raise a bare sentence. The
    # diagnostic that would normally help is unavailable BY DESIGN: a failure
    # inside a reveal window refuses to screenshot, because the secret is on
    # the screen. So the page's own text, redacted, is the evidence — and a
    # browser that FAILED is told apart from a page that simply says something
    # else, because those have nothing to do with each other.
    def confirm!(page, text, complaint)
      found = begin
        page_has_text?(page, text)
      rescue ::Selenium::WebDriver::Error::WebDriverError => error
        raise "#{complaint}: the browser itself failed reading the page " \
              "(#{error.class}: #{SecretHygiene.redact(error.message)})"
      end
      return if found

      raise "#{complaint} — #{page_state(page)}"
    end

    # Chrome answers "Node with given id does not belong to the document" when a
    # Turbo render replaces the document under Capybara's text wait; the page is
    # fine, the node it was reading is not. One re-read after that specific error
    # is the harness's whole tolerance (round-history: the detached-node race).
    DETACHED_NODE = /does not belong to the document/
    def page_has_text?(page, text)
      page.has_text?(text)
    rescue ::Selenium::WebDriver::Error::UnknownError => error
      raise unless DETACHED_NODE.match?(error.message)

      page.has_text?(text)
    end

    PAGE_STATE_LIMIT = 400

    def page_state(page)
      readable = SecretHygiene.redact(page.text).gsub(/\s+/, " ").strip
      "at #{page.current_path}, the page reads: #{readable[0, PAGE_STATE_LIMIT]}"
    rescue ::Selenium::WebDriver::Error::WebDriverError => error
      "the page could not be read at all (#{error.class})"
    end

    def actor(role)
      @speakers[role] ||= provision_human(role)
    end

    # One Human, end to end through public HTML: admin direct-create with a
    # temporary password, the forced-password ceremony, then a self-minted
    # member token from Settings.
    def provision_human(role)
      suffix = SecureRandom.hex(4)
      display_name = "#{ROLE_NAMES.fetch(role)} #{suffix}"
      email = "e2e-#{role.to_s.tr("_", "-")}-#{suffix}@e2e.test"
      temporary_password = SecretHygiene.register("temp pass #{SecureRandom.hex(8)}")
      password = SecretHygiene.register("final pass #{SecureRandom.hex(8)}")

      public_id = with_owner_browser do |owner|
        create_member(owner, display_name: display_name, email: email, temporary_password: temporary_password)
      end
      member_token = complete_first_sign_in(
        email: email, temporary_password: temporary_password, password: password
      )

      Speaker.new(
        role: role,
        display_name: display_name,
        email: email,
        password: password,
        public_id: public_id,
        member_token: member_token,
      )
    end

    # First-boot signup exists once per database; afterwards the owner signs
    # back in through the ordinary public form — the same tolerant pattern
    # the connection journeys use.
    def found_or_sign_in_owner(actor)
      page = actor.page
      actor.visit("/setup")
      if page.has_field?("Installation name", wait: 2)
        fill_form!(page, {
          "Installation name" => "E2E",
          "Your name" => OWNER_DISPLAY_NAME,
          "Email" => OWNER_EMAIL,
          "Password" => OWNER_PASSWORD,
          "Repeat password" => OWNER_PASSWORD,
        })
        page.click_button "Create installation"
      else
        actor.visit("/session/new")
        fill_form!(page, { "Email" => OWNER_EMAIL, "Password" => OWNER_PASSWORD })
        SessionSignInBudget.consume
        page.click_button "Sign in"
      end
      confirm!(page, "Dashboard", "the founding owner could not reach the dashboard")
    end

    # The mail-less admin direct-create flow: the typed temporary password is a secret in the DOM
    # until the redirect to the member's show page confirms the form is gone.
    def create_member(owner, display_name:, email:, temporary_password:)
      page = owner.page
      owner.visit("/admin/users/new")
      fill_form!(page, { "Display name" => display_name, "Email" => email })
      page.select "Member", from: "Role"
      SecretHygiene.during_reveal do
        fill_form!(page, {
          "Temporary password" => temporary_password,
          "Repeat temporary password" => temporary_password,
        })
        page.click_button "Create member"
        confirm!(page, "Member created.", "the admin direct-create flow did not confirm")
      end
      member_public_id_from(page.current_path)
    end

    # The public forced-password ceremony: signing in with the temporary
    # password reaches only the password wall; changing it completes the
    # Human's onboarding. Both password fields are secrets in the DOM until
    # the change confirmation renders.
    def complete_first_sign_in(email:, temporary_password:, password:)
      actor = BrowserActor.new(@base_url)
      page = actor.page
      SecretHygiene.during_reveal do
        actor.visit("/session/new")
        fill_form!(page, { "Email" => email, "Password" => temporary_password })
        SessionSignInBudget.consume
        page.click_button "Sign in"
        confirm!(page, "Set your own password to continue.", "the forced-password wall did not appear")

        fill_form!(page, {
          "Current password" => temporary_password,
          "New password" => password,
          "Repeat new password" => password,
        })
        page.click_button "Change password"
        confirm!(page, "Password changed.", "the password change did not confirm")
      end
      mint_member_token(actor, password)
    ensure
      actor&.close
    end

    # Settings token issuance: the reveal is the create response itself, so the ceremony captures
    # the secret and immediately leaves the page — the wire secret exists exactly once.
    #
    # The reveal window opens one line before a secret is actually typed, so
    # that both fields are filled and read back together: a document replaced
    # between them is exactly what this step has to notice. Widening the window
    # only refuses more screenshots, which is the safe direction.
    def mint_member_token(actor, password)
      page = actor.page
      actor.visit("/settings/tokens")
      secret = nil
      SecretHygiene.during_reveal do
        fill_form!(page, { "Name" => "e2e member automation", "Current password" => password })
        page.click_button "Create token"
        confirm!(page, "Token created", "the token reveal page did not appear")

        secret = page.find("input[name='access_token_secret']").value
        page.click_link "Done"
        confirm!(page, "New token", "the reveal page was not left")
        raise "the token secret is still in the DOM" if page.has_selector?("input[name='access_token_secret']", wait: 0)
      end
      raise "the revealed token is not a member bearer" unless secret&.start_with?("sk-cybros-api-v1-")

      SecretHygiene.register(secret)
    end

    def find_member_public_id(owner_actor, display_name)
      page = owner_actor.page
      owner_actor.visit("/admin/users")
      page.click_link display_name
      confirm!(page, "Member administration", "the member page did not open")

      member_public_id_from(page.current_path)
    end

    def member_public_id_from(path)
      public_id = path[%r{\A/admin/users/([0-9a-f-]+)\z}, 1]
      raise "could not read a member public id from #{path}" unless public_id

      public_id
    end
  end
end
