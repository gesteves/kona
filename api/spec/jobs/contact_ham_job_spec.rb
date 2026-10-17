require "rails_helper"

RSpec.describe ContactHamJob do
  let(:akismet) { instance_double(Akismet) }
  let(:context) { { "ip" => "203.0.113.7", "user_agent" => "Mozilla/5.0", "city" => "Boise" } }

  before { allow(Akismet).to receive(:new).and_return(akismet) }

  it "reports the false positive to Akismet" do
    allow(akismet).to receive(:submit_ham).and_return(true)

    described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context)

    expect(akismet).to have_received(:submit_ham).with(
      content: "Hello!", author: "Jane Rider", author_email: "jane@example.com",
      user_ip: "203.0.113.7", user_agent: "Mozilla/5.0"
    )
  end

  it "lets an Akismet failure propagate so Sidekiq retries the report" do
    allow(akismet).to receive(:submit_ham).and_raise(ApplicationService::HttpError.new(500, "down", "rest.akismet.com"))

    expect { described_class.new.perform("Jane Rider", "jane@example.com", "Hello!", context) }
      .to raise_error(ApplicationService::HttpError)
  end
end
