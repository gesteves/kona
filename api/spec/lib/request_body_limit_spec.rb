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

  # ⚠️ The first prefix match wins, thus `/social/photos` must stay above `/social`. Its limit is
  # above `Admin::SocialPhotosController::MAX_BYTES`, thus the action gives the message and this
  # middleware catches only a body that is far larger.
  it "gives the photo upload its own limit, and keeps the small one on the rest of the page" do
    expect(status_for("/social/photos", length: Admin::SocialPhotosController::MAX_BYTES)).to eq(200)
    expect(status_for("/social/photos", length: 65.megabytes)).to eq(413)
    expect(status_for("/social", length: 300.kilobytes)).to eq(413)
    expect(status_for("/social/preview/text", length: 300.kilobytes)).to eq(413)
  end

  # ⚠️ The same order rule as the photo upload: `/contentful/uploads/files` must stay above
  # `/contentful`, or one picked image gets the small limit of the page and a bare 413.
  it "gives the media upload its own limit, and keeps the small one on the rest of the page" do
    expect(status_for("/contentful/uploads/files", length: Admin::ContentfulUploadFilesController::MAX_BYTES)).to eq(200)
    expect(status_for("/contentful/uploads/files", length: 65.megabytes)).to eq(413)
    expect(status_for("/contentful/uploads", length: 300.kilobytes)).to eq(413)
    expect(status_for("/contentful/uploads", length: 200.kilobytes)).to eq(200)
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
