# frozen_string_literal: true

require "fileutils"
require "rake/testtask"
require "shellwords"

GEMSPEC = Gem::Specification.load("space-architect.gemspec")
GEM_FILE = File.join("pkg", "#{GEMSPEC.full_name}.gem")

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

def sh_unbundled(*command)
  if defined?(Bundler)
    Bundler.with_unbundled_env { sh(*command) }
  else
    sh(*command)
  end
end

desc "Build #{GEM_FILE}"
task :build do
  FileUtils.mkdir_p("pkg")
  FileUtils.rm_f(GEM_FILE)
  sh_unbundled "gem", "build", "space-architect.gemspec", "--output", GEM_FILE
end

desc "Install #{GEM_FILE} into the current Ruby user gem home"
task install: :build do
  install_args = ENV.fetch("INSTALL_ARGS", "--user-install --no-document").split
  sh_unbundled "gem", "install", *install_args, GEM_FILE
end

desc "Run mutation testing on Space::Architect::GateEvaluator and Space::Architect::GateLint"
task :mutant do
  sh "bundle", "exec", "mutant", "run", "--", "Space::Architect::GateEvaluator", "Space::Architect::GateLint"
end

# I16: the env-gated emission end-to-end — boots the REAL Hanami app from the
# all-fax-no-printer checkout (SPACE_E2E_AFNP_DIR), drives the real architect
# CLI as subprocesses through a full loop dance on a throwaway mini-space, and
# reads the natively-surfaced iteration back through the server's record read.
# Refuses loudly without SPACE_E2E_AFNP_DIR — never runs against dev implicitly.
# The driver runs UNDER afnp's bundle context (the gem's own bundle never loads
# afnp); the default :test task's pattern (test/**/*_test.rb) never picks the
# driver up (it is not a *_test.rb file).
namespace :test do
  desc "Run the emission end-to-end against the real space-server (requires SPACE_E2E_AFNP_DIR)"
  task :e2e do
    given = ENV["SPACE_E2E_AFNP_DIR"]
    abort "SPACE_E2E_AFNP_DIR must name the all-fax-no-printer checkout " \
          "(e.g. SPACE_E2E_AFNP_DIR=../all-fax-no-printer rake test:e2e)" if given.to_s.empty?

    # Resolution candidates: as given (cwd-relative, the absolute form), then
    # the space-relative bases the coordinator's cold run uses — the worktree
    # sits at <space>/build/<iteration>/wt, and the gem's in-space checkout
    # lives at <space>/repos/space-architect (whose ../all-fax-no-printer is
    # the I15-integrated tree). First candidate that is an afnp checkout
    # wins; none → loud abort, never an implicit dev run.
    space_root = File.expand_path("../../..", __dir__)
    candidates = [File.expand_path(given),
                  File.expand_path(given, space_root),
                  File.expand_path(given, File.join(space_root, "repos", "space-architect"))]
    afnp = candidates.find do |c|
      File.file?(File.join(c, "Gemfile")) && File.file?(File.join(c, "config", "routes.rb"))
    end
    abort "SPACE_E2E_AFNP_DIR=#{given} does not name an all-fax-no-printer checkout " \
          "(tried: #{candidates.join(', ')})" unless afnp

    gem_root = File.expand_path(__dir__)
    driver = File.join(gem_root, "test", "e2e", "iterations_emission_e2e.rb")
    command = "cd #{afnp.shellescape} && mise exec ruby@4.0.5 -- bundle exec ruby #{driver.shellescape} #{gem_root.shellescape}"
    # Unbundle: the task itself runs under the GEM's bundle, and an inherited
    # BUNDLE_GEMFILE would keep the afnp child on the gem's bundle — hanami
    # would never load. The driver must boot afnp under afnp's own bundle.
    sh_unbundled command
  end
end

task default: :test
