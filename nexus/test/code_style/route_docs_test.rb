require "test_helper"

# A route lands with its documentation. Every public Agent API and Platform API method/path pair
# must appear in its family's docs pages; adding a verb to an already-documented path must not
# bypass this pin.
class RouteDocsTest < ActiveSupport::TestCase
  DOCS = {
    %r{\A/agent_api/v1} => Rails.root.join("../docs/agent-api"),
    %r{\A/api/v1} => Rails.root.join("../docs/platform-api"),
  }.freeze

  test "every documented family route appears in its docs pages" do
    DOCS.each do |prefix, docs_root|
      corpus = docs_root.glob("**/*.md").map(&:read).join("\n")
      operations = Rails.application.routes.routes.filter_map do |route|
        path = route.path.spec.to_s.delete_suffix("(.:format)")
        next unless path.match?(prefix)

        [documented_verb(route.verb), path]
      end.uniq

      assert operations.any?, "no routes under #{prefix} — the pin is vacuous"
      operations.each do |verb, path|
        # Docs spell placeholders as {workspace_id}; routes as :public_id variants. Any braced name
        # satisfies the position.
        documented_path = Regexp.escape(path).gsub(/:[a-z_]+/, "\\{[a-z_]+\\}")
        pattern = Regexp.new(
          "(?:\\A|\\n)#{Regexp.escape(verb)}[ \\t]+#{documented_path}(?:[?\\s`]|\\z)"
        )
        assert corpus.match?(pattern),
          "#{verb} #{path} has no docs-page mention"
      end
    end
  end

  # ONE SPELLING PER VERB: an update on the member plane is PATCH alone — `resources
  # … only: :update` would mint a PUT twin beside it that no doc describes, so the five writers use
  # the member-patch idiom and PUT on them is a plain 404. The PUT-only doors (`runner`, `access`,
  # `lane`, `api_key`, the prompt-document slots) are the other spelling for the other shape: a
  # whole replacement of one column.
  test "the member plane's updates are PATCH alone: PUT on them does not route" do
    routes = Rails.application.routes
    workspace = "/agent_api/v1/workspaces/w"
    [
      "#{workspace}/conversations/c",
      "#{workspace}/conversations/c/inputs/i",
      "#{workspace}/conversations/c/turns/t",
      "#{workspace}/conversations/c/turns/t/variants/v",
      "#{workspace}/runs/l/inputs/i",
    ].each do |path|
      assert_equal "update", routes.recognize_path(path, method: :patch).fetch(:action), path
      assert_raises(ActionController::RoutingError, "PUT #{path} must not route") do
        routes.recognize_path(path, method: :put)
      end
    end
  end

  private

    # A MOUNTED RACK APP HAS NO VERB, and the cable is the one route in these
    # families that is a mount rather than an action. Its upgrade is an
    # ordinary GET, but calling it that in a route table would invite someone
    # to try it with curl and read the 404 as a broken endpoint — so the docs
    # spell it `WS`, and this is where the two spellings meet.
    def documented_verb(verb)
      verb.presence || "WS"
    end
end
