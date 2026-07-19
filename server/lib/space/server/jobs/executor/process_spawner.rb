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
          # => Handle (stdout/stderr IOs + wait/stop/kill verbs)
          def call(argv, env:)
            stdout_r, stdout_w = IO.pipe
            stderr_r, stderr_w = IO.pipe
            pid = Process.spawn(env, *argv, out: stdout_w, err: stderr_w)
            stdout_w.close
            stderr_w.close
            Handle.new(pid, stdout_r, stderr_r)
          end

          class Handle
            attr_reader :stdout, :stderr

            def initialize(pid, stdout, stderr)
              @pid    = pid
              @stdout = stdout
              @stderr = stderr
            end

            # Reaps the child; exit code, or 128+signal for a signaled child.
            def wait
              _, status = Process.wait2(@pid)
              status.exitstatus || (status.termsig ? 128 + status.termsig : 1)
            end

            def stop = signal(:TERM)
            def kill = signal(:KILL)

            private

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
