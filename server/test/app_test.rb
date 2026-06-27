# frozen_string_literal: true

require_relative "test_helper"

class AppTest < Minitest::Test
  def test_boots_successfully
    assert_kind_of Class, Space::Server::App
  end
end
