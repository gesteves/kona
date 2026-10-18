require "rails_helper"

RSpec.describe ContactMailJob do
  let(:akismet) { instance_double(Akismet) }
  let(:context) do
    { "ip" => "203.0.113.7", "port" => "54321", "user_agent" => "Mozilla/5.0", "city" => "Boise", "region" => "Idaho",
      "country" => "US", "network" => "Comcast Cable", "received_at" => "2026-08-01T11:59:48Z" }
  end

  before do
    allow(Akismet).to receive(:new).and_return(akismet)
    # By default there is no subject from the model. Thus these specs do not call the true Anthropic
    # API when a local .env has ANTHROPIC_API_KEY. Some examples change this.
    allow(ContactSubject).to receive(:generate).and_return(nil)
    # The same for the abuse check: by default the message is not abusive.
    allow(ContactModeration).to receive(:abusive?).and_return(false)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTACT_TO_ADDRESS").and_return("owner@example.test")
    allow(ENV).to receive(:[]).with("TIME_ZONE").and_return("America/Los_Angeles")
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
        "text" => a_string_including(
          "Boise, Idaho, US", "IP: 203.0.113.7", "Source port: 54321", "Network: Comcast Cable", "Mozilla/5.0",
          "Submitted: Saturday, August 1, 2026, 4:59:48 AM PDT (2026-08-01T11:59:48Z)"
        ),
        "idempotency_key" => a_string_matching(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
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
      name: "Spammer", email: "spam@example.com", message: "buy now", context: context,
      reason: SpamQuarantine::AKISMET
    )
    expect(ContactModeration).not_to have_received(:abusive?)
    expect(ContactDeliveryJob.jobs).to be_empty
  end

  it "quarantines an abusive submission instead of enqueuing delivery, and makes no subject" do
    allow(akismet).to receive(:spam?).and_return(false)
    allow(ContactModeration).to receive(:abusive?).and_return(true)
    quarantine = instance_double(SpamQuarantine, store: "generated-id")
    allow(SpamQuarantine).to receive(:new).and_return(quarantine)

    described_class.new.perform("Troll", "troll@example.com", "You're an idiot.", context)

    expect(ContactModeration).to have_received(:abusive?).with(name: "Troll", message: "You're an idiot.")
    expect(quarantine).to have_received(:store).with(
      name: "Troll", email: "troll@example.com", message: "You're an idiot.", context: context,
      reason: SpamQuarantine::ABUSIVE
    )
    expect(ContactSubject).not_to have_received(:generate)
    expect(ContactDeliveryJob.jobs).to be_empty
  end

  # ⚠️ The abuse check fails closed, as Akismet does.
  it "lets an abuse-check failure propagate (so the intake retries) without quarantining or delivering" do
    allow(akismet).to receive(:spam?).and_return(false)
    allow(ContactModeration).to receive(:abusive?).and_raise(StandardError.new("anthropic down"))
    expect(SpamQuarantine).not_to receive(:new)

    expect { described_class.new.perform("Jane", "jane@example.com", "Hello!", context) }
      .to raise_error(StandardError, "anthropic down")
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
    it "skips both checks and delivers" do
      allow(akismet).to receive(:spam?)
      allow(akismet).to receive(:submit_ham)

      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context, true)

      expect(akismet).not_to have_received(:spam?)
      expect(ContactModeration).not_to have_received(:abusive?)
      expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(hash_including("reply_to" => "jane@example.com"))
    end

    # Admin::SpamController adds ContactHamJob, thus a failed report cannot stop the delivery.
    it "does not report the false positive itself" do
      allow(akismet).to receive(:submit_ham)

      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context, true)

      expect(akismet).not_to have_received(:submit_ham)
    end

    it "reports the original submission time rather than the moment it was released" do
      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!",
        context.merge("received_at" => "2026-08-01T12:00:00Z"), true)

      expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(
        hash_including("text" => a_string_including("Submitted: Saturday, August 1, 2026, 5:00:00 AM PDT (2026-08-01T12:00:00Z)"))
      )
    end

    it "delivers the message with the raw time when the stored time is not ISO 8601" do
      described_class.new.perform("Jane Rider", "jane@example.com", "Hello!",
        context.merge("received_at" => "yesterday"), true)

      expect(ContactDeliveryJob).to have_enqueued_sidekiq_job(
        hash_including("text" => a_string_including("Submitted: yesterday"))
      )
    end
  end

  # ⚠️ A contact message must never go away, thus the job uses the default retries of Sidekiq.
  it "retries with the default retries of Sidekiq and not for 24 hours" do
    expect(described_class.ancestors).to include(ContactJob)
    expect(described_class.get_sidekiq_options).to include("retry" => true, "retry_for" => nil)
  end
end
