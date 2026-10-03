require "test_helper"

# non-CRUD verbs become nested singular resources (`cards/:id/closure`), never custom actions — one
# small controller per verb, born on the family's scoped concern. This pins the agent family's
# routes to that shape (idiom #5, 2026-09-05).
class NestedResourceVerbsTest < ActiveSupport::TestCase
  # The body-addressed memory reads: `path` carries a slash, so `show` and
  # `delete` ride a POST body rather than the URL (routes.rb says why).
  ALLOWED = ['post :show, path: "show"', 'post :delete, path: "delete"'].freeze

  test "the agent family spells its verbs as nested resources, never custom actions" do
    family = Rails.root.join("config/routes.rb").read[/  namespace :agent_api do\n.*?\n  end\n/m]
    assert family, "the agent family's namespace block was not found"

    custom = family.lines.map(&:strip).grep(/\A(get|post|put|patch|delete) :\w+/) - ALLOWED
    assert_empty custom,
      "custom actions in the agent family (spell each as `resource :verb, only: :create`): #{custom.inspect}"
  end
end
