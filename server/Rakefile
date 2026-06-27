# frozen_string_literal: true

require "hanami/rake_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
end

# Add your custom rake tasks to the lib/tasks directory
Rake.add_rakelib "lib/tasks"
