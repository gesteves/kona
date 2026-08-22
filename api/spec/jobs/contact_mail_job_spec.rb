require "rails_helper"

RSpec.describe ContactMailJob do
  let(:akismet) { instance_double(Akismet) }
  let(:context) do
    { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "city" => "Boise", "region" => "Idaho", "country" => "US" }
  end

  before do
    allow(Akismet).to receive(:new).and_return(akismet)
    # By default there is no subject from the model. Thus these specs do not call the true Anthropic
    # API when a local .env has ANTHROPIC_API_KEY. Some examples change this.
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
    expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("subject" => "[Contact form] Question about Alcatraz wetsuit rules"))
  end

  it "falls back to a static subject when none is generated" do
    allow(akismet).to receive(:spam?).and_return(false)
    allow(ContactSubject).to receive(:generate).and_return(nil)

    described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context)

    expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("subject" => "[Contact form] New message from Jane Rider"))
  end

  it "quarantines a submission Akismet flags as spam instead of enqueuing delivery" do
    allow(akismet).to receive(:spam?).and_return(true)
    quarantine = instance_double(SpamQuarantine, store: "generated-id")
    allow(SpamQuarantine).to receive(:new).and_return(quarantine)

    described_class.new.perform("Spammer", "spam@example.com", "buy now", context)

    expect(quarantine).to have_received(:store).with(
      name: "Spammer", email: "spam@example.com", message: "buy now", context: context
    )
    expect(ContactDeliveryJob.jobs).to be_empty
  end

  # ⚠️ Akismet fails closed, and the store must stay after the check. Without that order, a failure of
  # Akismet fills the quarantine with correct mail that nothing checked.
  it "lets an Akismet failure propagate (so the intake retries) without quarantining or delivering" do
    allow(akismet).to receive(:spam?).and_raise(ApplicationService::HttpError.new(500, "down", "rest.akismet.com"))
    expect(SpamQuarantine).not_to receive(:new)

    expect { described_class.new.perform("Jane", "jane@example.com", "Hello!", context) }
      .to raise_error(ApplicationService::HttpError)
    expect(ContactDeliveryJob.jobs).to be_empty
  end

  describe "a message released from the spam quarantine" do
    before { allow(akismet).to receive(:submit_ham).and_return(true) }

    it "skips the Akismet check and delivers" do
      allow(akismet).to receive(:spam?)

      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context, true)

      expect(akismet).not_to have_received(:spam?)
      expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("reply_to" => "jane@example.com"))
    end

    it "reports the false positive back to Akismet" do
      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context, true)

      expect(akismet).to have_received(:submit_ham).with(
        content: "Hello!", author: "Jane Rider", author_email: "jane@example.com",
        user_ip: "203.0.113.7", user_agent: "Mozilla/5.0"
      )
    end

    # The training of the filter is not more important than the message.
    it "still delivers when the ham submission blows up" do
      allow(akismet).to receive(:submit_ham).and_raise(StandardError.new("akismet down"))

      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context, true)

      expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("reply_to" => "jane@example.com"))
    end

    it "reports the original submission time rather than the moment it was released" do
      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!",
        context.merge("received_at" => "2026-08-01T12:00:00Z"), true)

      expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(
        hash_including("text" => a_string_including("Submitted: 2026-08-01T12:00:00Z"))
      )
    end
  end

  it "retries failed jobs for up to 24 hours" do
    expect(described_class.get_sidekiq_options["retry_for"]).to eq(24.hours)
  end
end
