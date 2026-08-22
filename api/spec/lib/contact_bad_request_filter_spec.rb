require "rails_helper"

RSpec.describe ContactBadRequestFilter do
  # Bugsnag::Report has both of these as public methods, and instance_double checks that they stay
  # public.
  def report(error:, env: nil)
    instance_double(Bugsnag::Report, original_error: error, request_data: { rack_env: env })
  end

  let(:bad_request) do
    ActionController::BadRequest.new("Invalid request parameters: Invalid encoding for parameter: hi")
  end
  let(:contact_post) { { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/api/contact" } }

  it "drops a BadRequest from a contact-form submission" do
    expect(described_class.call(report(error: bad_request, env: contact_post))).to be(false)
  end

  it "keeps a BadRequest from another endpoint" do
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/webhooks/contentful" }

    expect(described_class.call(report(error: bad_request, env: env))).to be(true)
  end

  it "keeps a BadRequest from a GET on the contact path" do
    env = { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/api/contact" }

    expect(described_class.call(report(error: bad_request, env: env))).to be(true)
  end

  it "keeps an unrelated error raised by a contact-form submission" do
    expect(described_class.call(report(error: StandardError.new("boom"), env: contact_post))).to be(true)
  end

  it "keeps a BadRequest raised outside a request" do
    expect(described_class.call(report(error: bad_request))).to be(true)
  end
end
