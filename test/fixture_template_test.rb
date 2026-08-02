# frozen_string_literal: true

require_relative "test_helper"

# Pins the property Grounds G2 identified: a fixture template must survive
# concurrent copying. Git's own auto-maintenance (spawned in the background by
# `git commit`, see Space::GitFixtureTemplate.init_repo) briefly takes
# `.git/objects/maintenance.lock`; FileUtils.cp_r's directory walk sees that
# file appear and disappear mid-walk and raises Errno::ENOENT. Uses a yaml
# key unique to this run so `space_dir` builds a fresh template — a
# already-memoized one from an earlier test has long since finished
# maintenance and can't exercise the race.
class FixtureTemplateTest < Minitest::Test
  def test_template_survives_concurrent_copying
    dir = Space::GitFixtureTemplate.space_dir("fixture_template_test: #{rand}\n")

    errors = 0
    60.times do
      Dir.mktmpdir("fixture-template-test") { |t| FileUtils.cp_r(File.join(dir, ".git"), t) }
    rescue Errno::ENOENT
      errors += 1
    end

    assert_equal 0, errors, "FileUtils.cp_r hit #{errors}/60 ENOENT races against git auto-maintenance"
  end
end
