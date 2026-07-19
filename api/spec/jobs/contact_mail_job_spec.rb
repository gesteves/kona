require "rails_helper"

RSpec.describe ContactMailJob do
  let(:akismet) { instance_double(Akismet) }
  let(:mailer) { instance_double(Resend) }

  before do
    allow(Akismet).to receive(:new).and_return(akismet)
    allow(Resend).to receive(:new).and_return(mailer)
    allow(mailer).to receive(:send_email)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTACT_TO_ADDRESS").and_return("owner@example.test")
  end

  let(:context) do
    { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "city" => "Boise", "region" => "Idaho", "country" => "US" }
  end

  it "emails a clean submission to the owner with Reply-To and enriched sender details" do
    allow(akismet).to receive(:spam?).and_return(false)

    described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context)

    expect(akismet).to have_received(:spam?).with(
      content: "Hello!", author: "Jane Rider", author_email: "jane@example.com",
      user_ip: "203.0.113.7", user_agent: "Mozilla/5.0"
    )
    expect(mailer).to have_received(:send_email).with(
      hash_including(
        to: "owner@example.test", reply_to: "jane@example.com",
        subject: a_string_including("Jane Rider"),
        text: a_string_including("Boise, Idaho, US", "203.0.113.7", "Mozilla/5.0")
      )
    )
  end

  it "drops a submission Akismet flags as spam without emailing" do
    allow(akismet).to receive(:spam?).and_return(true)

    described_class.new.perform("Spammer", "spam@example.com", "buy now")

    expect(mailer).not_to have_received(:send_email)
  end

  it "is configured to retry" do
    expect(described_class.get_sidekiq_options["retry"]).to eq(5)
  end
end
