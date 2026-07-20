# frozen_string_literal: true

module Space
  module Server
    module Jobs
      class Executor
        # The process-spawn seam (tests inject a fake). Secrets ride ONLY in the
        # child's environment — never argv. Pipe reads and Process.wait2 are
        # fiber-scheduler-aware under Async (Async::Scheduler#process_wait), so
        # pumps and wait cooperate with the reactor instead of blocking it.
        class ProcessSpawner
          # => Handle (stdout/stderr IOs + wait/stop/kill verbs). cidfile names
          # the file `container run --cidfile` writes the container ID to, so
          # stop/kill can act on the container itself.
          def call(argv, env:, cidfile: nil)
            stdout_r, stdout_w = IO.pipe
            stderr_r, stderr_w = IO.pipe
            pid = Process.spawn(env, *argv, out: stdout_w, err: stderr_w)
            stdout_w.close
            stderr_w.close
            Handle.new(pid, stdout_r, stderr_r, cidfile: cidfile)
          end

          class Handle
            attr_reader :stdout, :stderr

            def initialize(pid, stdout, stderr, cidfile: nil)
              @pid     = pid
              @stdout  = stdout
              @stderr  = stderr
              @cidfile = cidfile
            end

            # Reaps the child; exit code, or 128+signal for a signaled child.
            def wait
              _, status = Process.wait2(@pid)
              status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
            end

            # Apple `container` 1.0.0 never stops the sandbox via client
            # signals: the client swallows TERM (broken XPC signal forwarding)
            # and KILL orphans a still-running container (I09 P5). Stop acts on
            # the container by ID; kill does the same, then KILLs the client so
            # #wait always returns. Client signals remain as the fallback for a
            # spawn that never wrote a cidfile.
            def stop
              container_verb("stop") || signal(:TERM)
            end

            def kill
              container_verb("kill")
              signal(:KILL)
            end

            private

            # Runs `container <verb> <cid>` synchronously (Process.wait2 yields
            # to the reactor); false when no container ID is available.
            def container_verb(verb)
              cid = container_id
              return false unless cid

              pid = Process.spawn("container", verb, cid, out: File::NULL, err: File::NULL)
              _, status = Process.wait2(pid)
              status.success?
            end

            def container_id
              return nil unless @cidfile && File.exist?(@cidfile)

              cid = File.read(@cidfile).strip
              cid.empty? ? nil : cid
            end

            def signal(sig)
              Process.kill(sig, @pid)
            rescue Errno::ESRCH
              nil
            end
          end
        end
      end
    end
  end
end
