require "rails_helper"

RSpec.describe PlainTextExceptions do
  # ActionDispatch::ShowExceptions rewrites PATH_INFO to "/<status>" before calling the app.
  def call(path, method: "GET")
    described_class.call(Rack::MockRequest.env_for(path, method: method))
  end

  it "renders a 404 as plain text" do
    status, headers, body = call("/404")

    expect(status).to eq(404)
    expect(headers["content-type"]).to eq("text/plain; charset=utf-8")
    expect(body).to eq(["404 Not Found\n"])
    expect(headers["content-length"]).to eq("404 Not Found\n".bytesize.to_s)
  end

  it "renders a 500 as plain text" do
    status, _headers, body = call("/500")

    expect(status).to eq(500)
    expect(body).to eq(["500 Internal Server Error\n"])
  end

  it "falls back to 500 for a non-error status path" do
    status, _headers, body = call("/")

    expect(status).to eq(500)
    expect(body).to eq(["500 Internal Server Error\n"])
  end

  it "returns an empty body for HEAD requests" do
    status, headers, body = call("/404", method: "HEAD")

    expect(status).to eq(404)
    expect(body).to eq([])
    expect(headers["content-length"]).to eq("0")
  end
end
