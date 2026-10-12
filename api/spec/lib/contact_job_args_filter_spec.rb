require "rails_helper"

RSpec.describe ContactJobArgsFilter do
  def report(metadata)
    instance_double(Bugsnag::Report, metadata: metadata)
  end

  def sidekiq_tab(job_class)
    msg = { "class" => job_class, "args" => [ "Ada", "ada@example.com", "Hello", { "ip" => "203.0.113.1" } ], "queue" => "default" }
    { sidekiq: { msg: msg, queue: "default" } }
  end

  it "removes the arguments of a contact-form job and keeps the report" do
    metadata = sidekiq_tab("ContactMailJob")

    expect(described_class.call(report(metadata))).to be(true)
    expect(metadata[:sidekiq][:msg]).not_to have_key("args")
    expect(metadata[:sidekiq][:msg]["class"]).to eq("ContactMailJob")
  end

  it "removes the arguments of the delivery job" do
    metadata = sidekiq_tab("ContactDeliveryJob")

    described_class.call(report(metadata))

    expect(metadata[:sidekiq][:msg]).not_to have_key("args")
  end

  # The tab holds the job Hash of Sidekiq, and the retry needs its arguments.
  it "does not change the job Hash itself" do
    metadata = sidekiq_tab("ContactMailJob")
    job = metadata[:sidekiq][:msg]

    described_class.call(report(metadata))

    expect(job["args"]).to be_present
  end

  it "keeps the arguments of each other job" do
    metadata = sidekiq_tab("AssetSyncJob")

    expect(described_class.call(report(metadata))).to be(true)
    expect(metadata[:sidekiq][:msg]["args"]).to be_present
  end

  it "keeps a report with no Sidekiq tab" do
    expect(described_class.call(report({}))).to be(true)
  end
end
