require "rails_helper"

RSpec.describe ContactMailJob do
  let(:akismet) { instance_double(Akismet) }
  let(:context) do
    { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "city" => "Boise", "region" => "Idaho", "country" => "US" }
  end

  before do
    allow(Akismet).to receive(:new).and_return(akismet)
    # Default to no generated subject so these specs don't hit the real Anthropic API when a
    # local .env has ANTHROPIC_API_KEY; specific examples override this.
    allow(ContactSubject).to receive(:generate).and_return(nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTACT_TO_ADDRESS").and_return("owner@example.test")
  end

  it "spam-checks a clean submission and enqueues a delivery job with the composed email" do
    allow(akismet).to receive(:spam?).and_return(false)

    described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context)

    expect(akismet).to have_received(:spam?).with(
      content: "Hello!", author: "Jane Rider", author_email: "jane@example.com",
      user_ip: "203.0.113.7", user_agent: "Mozilla/5.0"
    )
    expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(
      hash_including(
        "to" => "owner@example.test",
        "reply_to" => "jane@example.com",
        "text" => a_string_including("Boise, Idaho, US", "203.0.113.7", "Mozilla/5.0")
      )
    )
  end

  it "uses the Claude-generated subject when available" do
    allow(akismet).to receive(:spam?).and_return(false)
    allow(ContactSubject).to receive(:generate).and_return("Question about Alcatraz wetsuit rules")

    described_class.new.perform("Jane Rider", "jane@example.com", "Do I need a wetsuit?", context)

    expect(ContactSubject).to have_received(:generate).with(name: "Jane Rider", message: "Do I need a wetsuit?")
    expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("subject" => "Question about Alcatraz wetsuit rules"))
  end

  it "falls back to a static subject when none is generated" do
    allow(akismet).to receive(:spam?).and_return(false)
    allow(ContactSubject).to receive(:generate).and_return(nil)

    described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context)

    expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("subject" => "New contact form message from Jane Rider"))
  end

  it "drops a submission Akismet flags as spam without enqueuing delivery" do
    allow(akismet).to receive(:spam?).and_return(true)

    described_class.new.perform("Spammer", "spam@example.com", "buy now")

    expect(ContactDeliveryJob.jobs).to be_empty
  end

  it "lets an Akismet failure propagate (so the intake retries) and does not enqueue delivery" do
    allow(akismet).to receive(:spam?).and_raise(ApplicationService::HttpError.new(500, "down", "rest.akismet.com"))

    expect { described_class.new.perform("Jane", "jane@example.com", "Hello!", context) }
      .to raise_error(ApplicationService::HttpError)
    expect(ContactDeliveryJob.jobs).to be_empty
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
