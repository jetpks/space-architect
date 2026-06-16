# frozen_string_literal: true

require_relative "test_helper"

class SluggerTest < SpaceCadetTest
  def test_slugifies_titles
    assert_equal "name-of-space", SpaceCadet::Slugger.slug("Name of Space")
    assert_equal "rx-1234-fix-profile-loading", SpaceCadet::Slugger.slug("RX-1234: Fix profile loading")
    assert_equal "space", SpaceCadet::Slugger.slug("!!!")
  end
end
