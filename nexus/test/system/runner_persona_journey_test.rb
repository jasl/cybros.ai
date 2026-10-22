require "application_system_test_case"

module RunnerPersonaJourney
  extend ActiveSupport::Concern

  included do
    test "managed tool connections lead to saved machine facts and Persona edits retain failed input" do
      human = users(:member)
      runner = connect_runner(manager: human, display_name: "Runner#{"x" * 94}").executor_access_token.executor
      assert_predicate runner.announce(
        services: { runner.executor_kind => { "tools" => [{ "name" => "read", "description" => "Read project files",
          "input_schema" => { "type" => "object" }, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }],
        "documents" => [{ "name" => "project", "description" => "Project instructions" }],
        "environment" => { "root" => "/srv/#{"workspace" * 30}" } } }
      ), :accepted?
      sign_in_directly(human)
      visit settings_mcp_connections_url
      click_link "Managed runners"
      assert_current_path runners_path(kind: "runner")
      find_link(runner.display_name).send_keys(:enter)
      assert_current_path runner_path(runner)
      assert_text "Overview"
      find("summary", text: "Direct access as you", exact_text: true).click
      assert_text "Allowed"
      find("summary", text: "read", exact_text: true).click
      assert_text "Read project files"
      find("summary", text: "Environment details", exact_text: true).click
      assert_text "/srv/workspace"
      assert_runner_persona_width
      click_link "View 0 related runs"
      assert_current_path runner_runs_path(runner)
      assert_text "No runs to show."
      page.go_back
      assert_current_path runner_path(runner)

      visit settings_url
      within("turbo-frame#settings") { click_link "Persona" }
      assert_current_path settings_persona_path
      assert_text "You have no saved Persona document."
      select "Developer", from: "Prompt role"
      fill_in "Persona content", with: "{{unknown_macro}}"
      click_button "Save Persona"
      assert_current_path settings_persona_path
      assert_text "Unknown macro: unknown_macro"
      assert_field "Persona content", with: "{{unknown_macro}}"
      assert_select "Prompt role", selected: "Developer"
      fill_in "Persona content", with: "Prefer short answers."
      click_button "Save Persona"
      assert_text "Persona saved."
      assert_field "Persona content", with: "Prefer short answers."
      fill_in "Persona content", with: ""
      click_button "Save Persona"
      assert_text "Version 2"
      assert_button "Delete Persona"
      assert_runner_persona_width
      confirm_through_dialog { click_button "Delete Persona" }
      assert_text "Persona deleted."
      assert_text "You have no saved Persona document."
      assert_no_button "Delete Persona"
    end
  end

  private

    def assert_runner_persona_width
      viewport_width = page.evaluate_script("document.documentElement.clientWidth")
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport_width + 1
    end
end

class RunnerPersonaJourneyTest < ApplicationSystemTestCase
  include RunnerPersonaJourney
end

class MobileRunnerPersonaJourneyTest < MobileSystemTestCase
  include RunnerPersonaJourney
end
