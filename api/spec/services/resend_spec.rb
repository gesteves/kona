require "rails_helper"

RSpec.describe Resend do
  subject(:service) { described_class.new(api_key: "re_test", from: "contact@example.test") }

  let(:send_args) do
    { to: "owner@example.test", subject: "New message", text: "body", reply_to: "jane@example.com" }
  end

  def stub_response(success:, body:)
    allow(HTTParty).to receive(:post).and_return(
      instance_double(HTTParty::Response, success?: success, code: success ? 200 : 422, body: body, request: nil)
    )
  end

  it "posts to the Resend emails endpoint with the sender's Reply-To and the verified from" do
    stub_response(success: true, body: { id: "abc-123" }.to_json)

    service.send_email(**send_args)

    expect(HTTParty).to have_received(:post).with(
      "https://api.resend.com/emails",
      hash_including(
        headers: hash_including("Authorization" => "Bearer re_test"),
        body: a_string_including('"reply_to":"jane@example.com"', '"from":"contact@example.test"', '"to":"owner@example.test"')
      )
    )
  end

  it "raises on a non-2xx response so the job retries" do
    stub_response(success: false, body: { statusCode: 422, message: "Invalid" }.to_json)
    expect { service.send_email(**send_args) }.to raise_error(ApplicationService::HttpError)
  end

  it "raises when unconfigured" do
    unconfigured = described_class.new(api_key: nil, from: nil)
    expect { unconfigured.send_email(**send_args) }.to raise_error(/not configured/)
  end
end
