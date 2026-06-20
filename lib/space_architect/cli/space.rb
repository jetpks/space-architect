# frozen_string_literal: true

SpaceArchitect::CLI::Registry.register "space" do |prefix|
  prefix.register "init",    SpaceArchitect::CLI::Init
  prefix.register "new",     SpaceArchitect::CLI::New
  prefix.register "list",    SpaceArchitect::CLI::List
  prefix.register "ls",      SpaceArchitect::CLI::List
  prefix.register "show",    SpaceArchitect::CLI::Show
  prefix.register "path",    SpaceArchitect::CLI::Path
  prefix.register "use",     SpaceArchitect::CLI::Use
  prefix.register "current", SpaceArchitect::CLI::Current
  prefix.register "status",  SpaceArchitect::CLI::Status
  prefix.register "config" do |c|
    c.register "show", SpaceArchitect::CLI::Config::Show
    c.register "path", SpaceArchitect::CLI::Config::ConfigPath
    c.register "set",  SpaceArchitect::CLI::Config::Set
  end
  prefix.register "repo" do |r|
    r.register "add",     SpaceArchitect::CLI::Repo::Add
    r.register "list",    SpaceArchitect::CLI::Repo::RepoList
    r.register "ls",      SpaceArchitect::CLI::Repo::RepoList
    r.register "resolve", SpaceArchitect::CLI::Repo::Resolve
  end
  prefix.register "repos" do |r|
    r.register "add",     SpaceArchitect::CLI::Repo::Add
    r.register "list",    SpaceArchitect::CLI::Repo::RepoList
    r.register "ls",      SpaceArchitect::CLI::Repo::RepoList
    r.register "resolve", SpaceArchitect::CLI::Repo::Resolve
  end
  prefix.register "shell" do |s|
    s.register "init",     SpaceArchitect::CLI::Shell::ShellInit
    s.register "fish",     SpaceArchitect::CLI::Shell::Fish
    s.register "complete", SpaceArchitect::CLI::Shell::Complete
  end
end
