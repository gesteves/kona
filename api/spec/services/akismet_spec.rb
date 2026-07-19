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

  it "fails open (ham) on an unexpected response body, e.g. an invalid key" do
    stub_response(success: true, body: "invalid")
    expect(service.spam?(**check_args)).to be(false)
  end

  it "fails open (ham) on an upstream error" do
    allow(HTTParty).to receive(:post).and_raise(StandardError.new("boom"))
    expect(service.spam?(**check_args)).to be(false)
  end

  it "does not call Akismet when unconfigured, and treats the submission as ham" do
    allow(HTTParty).to receive(:post)
    unconfigured = described_class.new(api_key: nil, blog: "https://example.test")
    expect(unconfigured.spam?(**check_args)).to be(false)
    expect(HTTParty).not_to have_received(:post)
  end
end
