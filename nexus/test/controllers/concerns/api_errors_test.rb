require "test_helper"

# THE FAMILY'S PROMISE IS THAT A CODE DETERMINES A STATUS. `errors.json`
# publishes `status_by_code` so a caller may branch on the code alone, and this
# is where that holds — at the one renderer, rather than at every call site
# where someone has to remember.
#
# It did not hold before: a OneShot refusal named `content_too_large` shipped as
# 422 while the same code from a Workspace command shipped as 413, because the
# mapping lived only in the contract producer and nothing in production read it.
class APIErrorsTest < ActionDispatch::IntegrationTest
  class ProbeController < ActionController::API
    include APIErrors

    def show
      render_error(params[:code], "probe", status: params.fetch(:intended).to_i)
    end
  end

  setup do
    Rails.application.routes.draw do
      get "/zz_api_errors_probe" => "api_errors_test/probe#show"
    end
  end

  teardown { Rails.application.reload_routes! }

  test "a family code carries its published status whatever the call site intended" do
    Nexus::FamilyErrors::STATUS.each do |code, pinned|
      # 418 is deliberately absurd: whatever a call site passes, the family's
      # own answer is what reaches the wire.
      get "/zz_api_errors_probe", params: { code: code, intended: 418 }

      assert_equal pinned, response.status, "#{code} must carry its published status"
      assert_equal code, response.parsed_body.dig("error", "code")
    end
  end

  # And a resource's own vocabulary is untouched — those are open by
  # construction and carry whatever their own page documents.
  test "a code the family does not own keeps the status its resource chose" do
    get "/zz_api_errors_probe", params: { code: "unsupported_generation_parameter", intended: 422 }
    assert_response :unprocessable_entity

    get "/zz_api_errors_probe", params: { code: "not_authorized", intended: 403 }
    assert_response :forbidden
  end

  test "the published contract is this mapping rather than a second copy of it" do
    published = Nexus::Contract.pack.fetch("errors.json")

    assert_equal Nexus::FamilyErrors::STATUS, published.fetch("status_by_code")
    assert_equal Nexus::FamilyErrors::STATUS.keys.sort, published.fetch("family_codes").sort
  end
end
