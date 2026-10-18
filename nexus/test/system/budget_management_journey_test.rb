require "application_system_test_case"

module BudgetManagementJourney
  extend ActiveSupport::Concern

  included do
    test "a steward manages allowance and a Human reads only their own financial ledger" do
      human = users(:member)
      Accounts::ConfigureCostUnit.call(account: accounts(:cybros), cost_unit: "USD")
      own = UsageBudgets::Open.call(actor: users(:owner), target: human, amount: "1.000000000000000001",
        starts_at: 1.minute.ago, operation_key: "human-balance").budget
      own.update_columns(debited_amount: BigDecimal("2"))
      agent = create_agent_member(steward: human)
      sign_in_directly(human)

      visit settings_budgets_url
      assert_text "-0.999999999999999999"
      assert_no_link "Open budget window"
      click_link "View window and ledger"
      assert_current_path settings_budget_path(own.public_id)
      assert_text "Initial grant"
      assert_no_button "Revoke window"
      assert_budget_viewport

      visit agent_budgets_url(agent)
      assert_text "There is no current usable window"
      find_link("Open budget window", exact_text: true).send_keys(:enter)
      assert_current_path new_agent_budget_path(agent)
      key = find("input[name='budget[operation_key]']", visible: :all).value
      assert_selector "input[name='budget[starts_at]'][type=datetime-local][step='1']"
      starts_at = find_field("Starts at").value
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?\z/, starts_at)
      fill_in "Amount", with: "-1"
      fill_in "Reason (optional)", with: "An allowance for this Agent"
      click_button "Open budget window"
      assert_text "Check the amount, time window, and reason"
      assert_field "Starts at", with: starts_at
      assert_field "Amount", with: "-1"
      assert_equal key, find("input[name='budget[operation_key]']", visible: :all).value
      fill_in "Amount", with: "2.000000000000000001"
      click_button "Open budget window"
      assert_text "Budget window opened."
      assert_text "2.000000000000000001"
      click_link "Adjust amount"
      select "Deduct credit", from: "Adjustment kind"
      fill_in "Amount", with: "100"
      click_button "Save adjustment"
      assert_text "This deduction exceeds the window's remaining amount"
      assert_field "Amount", with: "100"
      assert_select "Adjustment kind", selected: "Deduct credit"
      fill_in "Amount", with: "1"
      fill_in "Reason (optional)", with: "Small deduction"
      click_button "Save adjustment"
      assert_text "Adjustment saved."
      assert_text "1.000000000000000001"
      assert_text "Small deduction"
      select "Latest first", from: "Order"
      fill_in "Per page", with: "1"
      click_button "Apply"
      assert_text "2 · Debit adjustment"
      assert_no_text "1 · Initial grant"
      click_link "Next page"
      assert_text "1 · Initial grant"
      assert_link "First page"
      assert_budget_viewport

      fill_in "revocation_reason", with: "Remove this cap"
      confirm_through_dialog { click_button "Revoke window" }
      assert_text "Budget window revoked."
      assert_text "Remove this cap"
      assert_no_button "Revoke window"
      click_link "All budget windows"
      assert_text "There is no current usable window"
      assert_budget_viewport
    end
  end

  private

    def assert_budget_viewport
      width = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width + 1
    end
end

class BudgetManagementJourneyTest < ApplicationSystemTestCase
  include BudgetManagementJourney
end

class MobileBudgetManagementJourneyTest < MobileSystemTestCase
  include BudgetManagementJourney
end
