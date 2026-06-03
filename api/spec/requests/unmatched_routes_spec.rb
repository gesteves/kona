require "rails_helper"

RSpec.describe "Unmatched routes", type: :request do
  it "returns a plain-text 404 for unknown paths instead of raising RoutingError" do
    get "/this/does/not/exist"

    expect(response).to have_http_status(:not_found)
    expect(response.content_type).to start_with("text/plain")
    expect(response.body).to eq("404 Not Found\n")
  end

  it "handles a scanner-style probe path" do
    get "/api/.env"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("404 Not Found\n")
  end

  it "returns 404 (not a CSRF 422) for non-GET probes to unknown paths" do
    post "/api/.env"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to eq("404 Not Found\n")
  end
end
