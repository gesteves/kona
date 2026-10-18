require "rails_helper"

RSpec.describe ContactDeliveryJob do
  let(:mailer) { instance_double(Resend) }
  let(:payload) do
    {
      "to" => "owner@example.test", "reply_to" => "jane@example.com",
      "subject" => "Question about Alcatraz wetsuit rules",
      "text" => "text body", "idempotency_key" => "key-1"
    }
  end

  before do
    allow(Resend).to receive(:new).and_return(mailer)
    allow(mailer).to receive(:send_email)
  end

  it "sends the composed email via Resend with the payload's fields" do
    described_class.new.perform(payload)

    expect(mailer).to have_received(:send_email).with(
      to: "owner@example.test", reply_to: "jane@example.com",
      subject: "Question about Alcatraz wetsuit rules", text: "text body",
      idempotency_key: "key-1"
    )
  end

  it "lets a Resend failure propagate so Sidekiq retries the send" do
    allow(mailer).to receive(:send_email).and_raise(ApplicationService::HttpError.new(429, "rate limited", "https://api.resend.com/emails"))

    expect { described_class.new.perform(payload) }.to raise_error(ApplicationService::HttpError)
  end

  # ⚠️ A contact message must never go away, thus the job uses the default retries of Sidekiq.
  it "retries with the default retries of Sidekiq and not for 24 hours" do
    expect(described_class.ancestors).to include(ContactJob)
    expect(described_class.get_sidekiq_options).to include("retry" => true, "retry_for" => nil)
  end
end
