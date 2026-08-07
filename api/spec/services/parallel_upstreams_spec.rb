require "rails_helper"

RSpec.describe ParallelUpstreams do
  subject(:runner) do
    Class.new do
      include ParallelUpstreams
      def run(**blocks) = in_parallel(**blocks)
    end.new
  end

  it "returns each block's value under its own key" do
    result = runner.run(a: -> { 1 }, b: -> { 2 })

    expect(result).to eq(a: 1, b: 2)
  end

  it "returns an empty hash when given nothing" do
    expect(runner.run).to eq({})
  end

  it "actually runs the blocks concurrently" do
    # Each block blocks until every other one has started, so this only completes if they are
    # genuinely running at the same time — serial execution would deadlock on the first.
    barrier = Queue.new
    started = Queue.new
    blocks = (1..3).to_h do |i|
      [:"job#{i}", -> { started << i; 3.times { barrier.pop }; i }]
    end

    thread = Thread.new { runner.run(**blocks) }
    3.times { started.pop }
    9.times { barrier << :go }

    expect(thread.value).to eq(job1: 1, job2: 2, job3: 3)
  end

  # The contract is that callers wrap their own blocks in `safely`. This documents what happens
  # when one doesn't, so nobody assumes the join swallows failures.
  it "propagates a raise from a block that was not isolated" do
    expect { runner.run(ok: -> { 1 }, boom: -> { raise "upstream down" }) }
      .to raise_error("upstream down")
  end
end
