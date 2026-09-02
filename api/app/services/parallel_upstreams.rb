# Does the upstream fetches that do not depend on each other, at the same time, for a widget action
# that calls more than one API. With a warm cache, each fetch is a Redis read and the order does not
# matter. With a cold cache, which occurs each five minutes and after each deploy, they were a chain
# of HTTP requests in sequence, in one request budget.
module ParallelUpstreams
  private

  # Runs each block on its own thread and returns the values under the same keys.
  #
  # ⚠️ Put each block in `safely` before you give it to this method. Thread#value raises the error of
  # the thread again. Thus an upstream call with no protection would stop the join and the widget,
  # and that is the opposite of the purpose of this method.
  #
  # ⚠️ Each thread runs in the Rails executor. A plain thread that causes an autoload can stop in
  # development, where Rails does not load each constant at the start.
  # @param blocks [Hash{Symbol => #call}] The fetches to do.
  # @return [Hash{Symbol => Object}] The value of each block, under its key.
  def in_parallel(**blocks)
    threads = blocks.map do |key, block|
      thread = Thread.new do
        # Thread#value below raises the error again, thus the stderr report of Ruby is a second
        # copy. Set it in the thread, before the block can raise.
        Thread.current.report_on_exception = false
        Rails.application.executor.wrap { block.call }
      end
      [ key, thread ]
    end

    # Join each thread before you read a value. Thread#value raises the error again, thus a read
    # first would leave the other threads in progress after the first failure.
    threads.each { |(_, thread)| thread.join }
    threads.to_h { |key, thread| [ key, thread.value ] }
  end
end
