# frozen_string_literal: true

Space::Architect::CLI::Registry.register "space" do |prefix|
  prefix.register "init",    Space::Architect::CLI::Init
  prefix.register "new",     Space::Architect::CLI::New
  prefix.register "list",    Space::Architect::CLI::List
  prefix.register "ls",      Space::Architect::CLI::List
  prefix.register "show",    Space::Architect::CLI::Show
  prefix.register "path",    Space::Architect::CLI::Path
  prefix.register "use",     Space::Architect::CLI::Use
  prefix.register "current", Space::Architect::CLI::Current
  prefix.register "status",  Space::Architect::CLI::Status
  prefix.register "config" do |c|
    c.register "show", Space::Architect::CLI::Config::Show
    c.register "path", Space::Architect::CLI::Config::ConfigPath
    c.register "set",  Space::Architect::CLI::Config::Set
  end
  prefix.register "repo" do |r|
    r.register "add",     Space::Architect::CLI::Repo::Add
    r.register "list",    Space::Architect::CLI::Repo::RepoList
    r.register "ls",      Space::Architect::CLI::Repo::RepoList
    r.register "resolve", Space::Architect::CLI::Repo::Resolve
  end
  prefix.register "repos" do |r|
    r.register "add",     Space::Architect::CLI::Repo::Add
    r.register "list",    Space::Architect::CLI::Repo::RepoList
    r.register "ls",      Space::Architect::CLI::Repo::RepoList
    r.register "resolve", Space::Architect::CLI::Repo::Resolve
  end
  prefix.register "shell" do |s|
    s.register "init",     Space::Architect::CLI::Shell::ShellInit
    s.register "fish",     Space::Architect::CLI::Shell::Fish
    s.register "complete", Space::Architect::CLI::Shell::Complete
  end
end
