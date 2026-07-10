require "rails_helper"

RSpec.describe WhoopWebhookJob do
  let(:processor) { instance_double(WhoopWebhookProcessor) }

  before { allow(WhoopWebhookProcessor).to receive(:new).and_return(processor) }

  it "delegates to the processor with the event's string args" do
    expect(processor).to receive(:process).with("workout.updated", "workout-uuid", "trace-1")
    described_class.new.perform("workout.updated", "workout-uuid", "trace-1")
  end

  it "is configured to retry" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(5)
  end
end
