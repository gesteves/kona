require "rails_helper"

RSpec.describe SidekiqRedisTimeoutFilter do
  # Bugsnag::Report has both of these as public methods, and instance_double checks that they stay
  # public.
  def report(error:, sidekiq: nil)
    instance_double(Bugsnag::Report, original_error: error, request_data: { sidekiq: sidekiq })
  end

  let(:fetch_timeout) { RedisClient::ReadTimeoutError.new("Waited 12 seconds") }
  let(:job) { { msg: { "class" => "AssetSyncJob", "queue" => "default" }, queue: "default" } }

  context "in the Sidekiq server process" do
    before { allow(Sidekiq).to receive(:server?).and_return(true) }

    it "drops a read timeout raised outside a job (the fetch loop)" do
      expect(described_class.call(report(error: fetch_timeout))).to be(false)
    end

    it "drops a write timeout raised outside a job" do
      error = RedisClient::WriteTimeoutError.new("Waited 12 seconds")

      expect(described_class.call(report(error: error))).to be(false)
    end

    # This is the purpose of the filter: a Redis that the code truly cannot reach raises
    # CannotConnectError, which is beside TimeoutError and not below it.
    it "keeps a connection failure, which is what a real outage raises" do
      error = RedisClient::CannotConnectError.new("Connection refused")

      expect(described_class.call(report(error: error))).to be(true)
    end

    it "keeps a read timeout raised by job code, which has Sidekiq job context" do
      expect(described_class.call(report(error: fetch_timeout, sidekiq: job))).to be(true)
    end

    it "keeps an unrelated error raised outside a job" do
      expect(described_class.call(report(error: StandardError.new("boom")))).to be(true)
    end
  end

  context "outside the Sidekiq server process (Puma)" do
    before { allow(Sidekiq).to receive(:server?).and_return(false) }

    it "keeps a read timeout, because a stalled enqueue affects a live request" do
      expect(described_class.call(report(error: fetch_timeout))).to be(true)
    end
  end
end
