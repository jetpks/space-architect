# frozen_string_literal: true

require "fileutils"

module RepoTender
  module State
    # Advisory process-level lock on a sidecar file derived from the
    # state file path. Serializes overlapping `sync` runs so the
    # later run bails cleanly rather than clobbering the in-flight
    # run's state with a last-writer-wins atomic rename (CF10).
    #
    # The lockfile is a persistent zero-byte sentinel — never unlinked.
    # Deleting a flock'd file while another fd holds it creates a race
    # where both processes think they hold the lock on different inodes.
    class Lock
      NOT_ACQUIRED = :not_acquired

      # Returns the sidecar lockfile path for a given state_file path.
      def self.path_for(state_file)
        "#{state_file}.lock"
      end

      # Acquires an exclusive non-blocking advisory lock on the sidecar
      # lockfile. Creates the file (and its parent directory) if missing.
      #
      # Yields to the block and returns its value when the lock is
      # acquired; releases the lock in an `ensure` so it is freed on
      # normal return, explicit `return`, AND any escaping exception
      # (including Interrupt / SignalException).
      #
      # Returns `NOT_ACQUIRED` *without* yielding when another process
      # already holds the lock. The caller decides what to do (e.g.
      # bail cleanly with a Success).
      def self.acquire(state_file)
        lock_path = path_for(state_file)
        FileUtils.mkdir_p(File.dirname(lock_path))
        f = File.open(lock_path, File::RDWR | File::CREAT)
        unless f.flock(File::LOCK_EX | File::LOCK_NB)
          f.close
          return NOT_ACQUIRED
        end
        begin
          yield
        ensure
          f.flock(File::LOCK_UN)
          f.close
        end
      end
    end
  end
end
