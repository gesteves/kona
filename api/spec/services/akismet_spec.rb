require "rails_helper"

RSpec.describe Akismet do
  subject(:service) { described_class.new(api_key: api_key, blog: "https://example.test") }

  let(:api_key) { "test-key" }
  let(:check_args) do
    { content: "Hello there!", author: "Jane", author_email: "jane@example.com", user_ip: "203.0.113.7", user_agent: "Mozilla/5.0" }
  end

  def stub_response(success:, body:)
    allow(HTTParty).to receive(:post).and_return(
      instance_double(HTTParty::Response, success?: success, body: body, code: success ? 200 : 500, request: nil)
    )
  end

  it "reports spam when Akismet answers \"true\"" do
    stub_response(success: true, body: "true")
    expect(service.spam?(**check_args)).to be(true)
  end

  it "reports ham when Akismet answers \"false\"" do
    stub_response(success: true, body: "false")
    expect(service.spam?(**check_args)).to be(false)
  end

  it "posts to the key-scoped comment-check endpoint with the required params" do
    stub_response(success: true, body: "false")
    service.spam?(**check_args)

    expect(HTTParty).to have_received(:post).with(
      "https://#{api_key}.rest.akismet.com/1.1/comment-check",
      hash_including(body: hash_including(blog: "https://example.test", user_ip: "203.0.113.7", comment_content: "Hello there!"))
    )
  end

  it "raises (fails closed) on a non-success response so the job retries rather than delivering" do
    stub_response(success: false, body: "")
    expect { service.spam?(**check_args) }.to raise_error(ApplicationService::HttpError)
  end

  it "raises (fails closed) on an unexpected body, e.g. an invalid-key \"invalid\" response" do
    stub_response(success: true, body: "invalid")
    expect { service.spam?(**check_args) }.to raise_error(ApplicationService::HttpError)
  end

  it "lets a transport error propagate so the job retries" do
    allow(HTTParty).to receive(:post).and_raise(StandardError.new("boom"))
    expect { service.spam?(**check_args) }.to raise_error(StandardError, "boom")
  end

  it "fails open (ham) when unconfigured, without calling Akismet" do
    allow(HTTParty).to receive(:post)
    unconfigured = described_class.new(api_key: nil, blog: "https://example.test")
    expect(unconfigured.spam?(**check_args)).to be(false)
    expect(HTTParty).not_to have_received(:post)
  end

  describe "#submit_ham" do
    it "posts to the key-scoped submit-ham endpoint with the same comment params" do
      stub_response(success: true, body: "Thanks for making the web a better place.")

      expect(service.submit_ham(**check_args)).to be(true)
      expect(HTTParty).to have_received(:post).with(
        "https://#{api_key}.rest.akismet.com/1.1/submit-ham",
        hash_including(body: hash_including(blog: "https://example.test", user_ip: "203.0.113.7", comment_content: "Hello there!"))
      )
    end

    # ⚠️ This is the opposite of #spam?, on purpose. It is for training, and a failure of it must
    # never stop a message that the owner already accepted.
    it "reports failure rather than raising, so a caller can shrug it off" do
      stub_response(success: false, body: "")
      expect(service.submit_ham(**check_args)).to be(false)
    end

    it "does nothing when unconfigured" do
      allow(HTTParty).to receive(:post)
      unconfigured = described_class.new(api_key: nil, blog: "https://example.test")

      expect(unconfigured.submit_ham(**check_args)).to be(false)
      expect(HTTParty).not_to have_received(:post)
    end
  end
end
