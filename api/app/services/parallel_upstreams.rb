# Runs independent upstream fetches concurrently, for widget actions that fan out to several
# unrelated APIs. Warm, every one of them is a Redis hit and the ordering is irrelevant; cold —
# every five minutes, and after every deploy — they were a serial chain of HTTP round trips inside
# a single request budget.
module ParallelUpstreams
  private

  # Runs each block on its own thread and returns the values under the same keys.
  #
  # ⚠️ Wrap each block in `safely` before passing it in. Thread#value re-raises whatever the
  # thread raised, so an unisolated upstream would take the whole join — and the widget — down,
  # which is the opposite of what the fan-out is for.
  #
  # ⚠️ Each thread runs inside the Rails executor. A bare thread that triggers autoloading can
  # deadlock in development, where constants aren't eager-loaded.
  # @param blocks [Hash{Symbol => #call}] The fetches to run.
  # @return [Hash{Symbol => Object}] Each block's value, under its key.
  def in_parallel(**blocks)
    threads = blocks.map do |key, block|
      thread = Thread.new { Rails.application.executor.wrap { block.call } }
      # The failure is delivered to the join below, so Ruby's own stderr report is duplicate noise.
      thread.report_on_exception = false
      [key, thread]
    end

    # Join everything before reading any value. Thread#value re-raises, so going straight to it
    # would abandon the remaining threads mid-flight on the first failure.
    threads.each { |(_, thread)| thread.join rescue nil }
    threads.to_h { |key, thread| [key, thread.value] }
  end
end
