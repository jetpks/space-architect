# frozen_string_literal: true

require_relative "test_helper"

class WarningsTest < Space::ArchitectTest
  def test_experimental_warning_disabled_at_load
    assert_equal false, Warning[:experimental]
  end
end
