require "rails_helper"

RSpec.describe ContactJob do
  # ⚠️ A contact message must never go away. A nil retry_for makes Sidekiq count the attempts, with
  # its default of 25.
  it "uses the default retries of Sidekiq for each contact job" do
    [ ContactMailJob, ContactDeliveryJob, ContactHamJob ].each do |job|
      expect(job.ancestors).to include(described_class)
      expect(job.get_sidekiq_options).to include("retry" => true, "retry_for" => nil)
    end
  end

  it "keeps the 24-hour window for each other job" do
    expect(ApplicationJob.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end

  it "still kills a job that raises a PermanentError" do
    expect(described_class.sidekiq_retry_in_block.call(1, ApplicationJob::PermanentError.new("x"))).to eq(:kill)
  end
end
