require "rails_helper"

RSpec.describe Turnstile do
  subject(:service) { described_class.new(secret: "ts-secret") }

  def stub_response(success:, body:)
    allow(HTTParty).to receive(:post).and_return(
      instance_double(HTTParty::Response, success?: success, code: success ? 200 : 500, body: body, request: nil)
    )
  end

  it "returns true for a token siteverify accepts, posting secret/response/remoteip" do
    stub_response(success: true, body: { success: true }.to_json)

    expect(service.verify("good-token", remoteip: "1.2.3.4")).to be(true)
    expect(HTTParty).to have_received(:post).with(
      "https://challenges.cloudflare.com/turnstile/v0/siteverify",
      hash_including(body: hash_including(secret: "ts-secret", response: "good-token", remoteip: "1.2.3.4"))
    )
  end

  it "returns false for a token siteverify rejects" do
    stub_response(success: true, body: { success: false, "error-codes": ["invalid-input-response"] }.to_json)
    expect(service.verify("bad-token")).to be(false)
  end

  it "returns false for a blank token, without calling siteverify" do
    allow(HTTParty).to receive(:post)
    expect(service.verify("")).to be(false)
    expect(HTTParty).not_to have_received(:post)
  end

  it "fails open (true) when unconfigured, without calling siteverify" do
    allow(HTTParty).to receive(:post)
    expect(described_class.new(secret: nil).verify("whatever")).to be(true)
    expect(HTTParty).not_to have_received(:post)
  end

  it "fails open (true) on a transport error (a token was presented, just unconfirmable)" do
    stub_response(success: false, body: "")
    expect(service.verify("good-token")).to be(true)
  end
end
