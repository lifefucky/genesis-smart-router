# frozen_string_literal: true
# encoding: UTF-8

require "minitest/autorun"

class ReadmeRunbookTest < Minitest::Test
  README_PATH = File.expand_path("../../README.md", __dir__)

  def test_readme_states_no_cli_and_manual_pipeline
    readme = File.read(README_PATH, encoding: "UTF-8")

    assert_includes readme, "нет единого CLI"
    assert_includes readme, "ручной сборкой batch-прохода"
    assert_match(
      /SmartRouter::RunInputs\.load.*?SmartRouter::HardConstraintsFilter\.filter.*?SmartRouter::BaselineSelector\.select.*?SmartRouter::DecisionRecordBuilder\.build.*?SmartRouter::RoutingDecisionsWriter\.write/m,
      readme
    )
  end

  def test_readme_warns_input_error_prevents_output_write
    readme = File.read(README_PATH, encoding: "UTF-8")

    assert_includes readme, "если на любой операции случится `InputError`, итоговый `tmp/routing_decisions.json` не будет записан"
  end

  def test_readme_keeps_epic_roadmap_brief_and_explicit
    readme = File.read(README_PATH, encoding: "UTF-8")

    assert_match(
      /Epic 2 - Resilient Fallback and Stateful Execution.*Epic 3 - Goal-Aware Smart Selection.*Epic 4 - Routing Analytics and Tuning Feedback/m,
      readme
    )
  end
end
