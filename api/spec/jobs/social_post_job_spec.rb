require "rails_helper"

# The shared enqueue of the next post of a thread. The three subclass specs test the posts; this
# spec tests the lock that stops a second job for one post.
RSpec.describe SocialPostJob do
  let(:job_class) do
    Class.new(SocialPostJob) do
      const_set(:ENQUEUE_LOCK_PREFIX, "spec:post:enqueue:")
      def self.name = "SpecPostJob"
      public :enqueue_next
    end
  end
  let(:job) { job_class.new }
  let(:posts) { [ { "key" => "k0", "text" => "one" }, { "key" => "k1", "text" => "two" } ] }

  before { allow(job_class).to receive(:perform_async) }

  it "adds the job of the next post one time only, with the rest of the arguments" do
    job.enqueue_next(posts, 1, "reply-ref")
    job.enqueue_next(posts, 1, "reply-ref")

    expect(job_class).to have_received(:perform_async).with(posts, 1, "reply-ref").once
    expect($redis.ttl("spec:post:enqueue:k1")).to be_within(5).of(SocialPostJob::ENQUEUE_LOCK_TTL)
  end

  it "adds nothing after the last post" do
    job.enqueue_next(posts, 2)

    expect(job_class).not_to have_received(:perform_async)
  end

  # ⚠️ A fallback key would be one lock that each thread shares, and the second post of each other
  # thread would then go away for 36 hours.
  it "adds nothing, and takes no lock, for a post with no key" do
    job.enqueue_next([ { "text" => "one" }, { "text" => "two" } ], 1)

    expect(job_class).not_to have_received(:perform_async)
    expect($redis.get("spec:post:enqueue:")).to be_nil
  end

  # ⚠️ A lock that stays after a failed enqueue makes the retry skip the rest of the thread, and
  # nothing reports it.
  it "gives the lock back and raises when the enqueue fails" do
    allow(job_class).to receive(:perform_async).and_raise(RedisClient::ReadTimeoutError)

    expect { job.enqueue_next(posts, 1) }.to raise_error(RedisClient::ReadTimeoutError)
    expect($redis.get("spec:post:enqueue:k1")).to be_nil
  end
end
