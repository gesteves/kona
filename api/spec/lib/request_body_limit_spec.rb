require "rails_helper"

RSpec.describe RequestBodyLimit do
  let(:app) { ->(_env) { [ 200, {}, [ "ok" ] ] } }
  let(:middleware) { described_class.new(app) }

  def status_for(path, method: "POST", length:)
    env = Rack::MockRequest.env_for(path, method: method, "CONTENT_LENGTH" => length.to_s)
    middleware.call(env).first
  end

  it "refuses a webhook body above one megabyte and permits one below it" do
    expect(status_for("/webhooks/contentful", length: 1.megabyte + 1)).to eq(413)
    expect(status_for("/webhooks/contentful", length: 1.megabyte)).to eq(200)
  end

  it "gives the course-map upload its own larger limit" do
    expect(status_for("/course-maps", length: 30.megabytes)).to eq(200)
    expect(status_for("/course-maps", length: 33.megabytes)).to eq(413)
  end

  it "applies the default to a path with no entry" do
    expect(status_for("/api/contact", length: 64.kilobytes)).to eq(200)
    expect(status_for("/api/location", length: 64.kilobytes + 1)).to eq(413)
  end

  it "ignores a request with no body" do
    expect(status_for("/widgets/weather/current", method: "GET", length: 50.megabytes)).to eq(200)
  end

  it "answers as plain text with no cache header" do
    env = Rack::MockRequest.env_for("/webhooks/whoop", method: "POST", "CONTENT_LENGTH" => (2.megabytes).to_s)
    status, headers, body = middleware.call(env)
    expect(status).to eq(413)
    expect(headers["content-type"]).to eq("text/plain; charset=utf-8")
    expect(headers).not_to have_key("cache-control")
    expect(body.join).to eq("413 Content Too Large\n")
  end

  describe "in the middleware stack", type: :request do
    it "answers a large webhook post before the signature check reads the body" do
      expect_any_instance_of(Webhooks::ContentfulController).not_to receive(:create)
      post "/webhooks/contentful", params: "x" * (1.megabyte + 1), headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:content_too_large)
    end
  end
end
