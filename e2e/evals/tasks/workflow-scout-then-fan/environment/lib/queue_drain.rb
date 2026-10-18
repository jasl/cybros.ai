# Mixed into a worker: takes every waiting job off its queue and runs it.
module QueueDrain
  def call
    done = 0
    until queue.empty?
      queue.shift.run
      done += 1
    end
    done
  end
end
