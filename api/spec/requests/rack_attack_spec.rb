require "rails_helper"

# Rack::Attack is disabled in the test env so the rest of the suite isn't rate-limited; these
# examples flip it on and use the in-memory store configured for test, resetting counters
# around each example so they don't leak across the shared 127.0.0.1 client IP.
RSpec.describe "Rack::Attack", type: :request do
  before do
    Rack::Attack.enabled = true
    Rack::Attack.cache.store.clear
  end

  after do
    Rack::Attack.cache.store.clear
    Rack::Attack.enabled = false
  end

  it "does not throttle or block legitimate (known-route) traffic" do
    30.times { get "/up" }

    expect(response).to have_http_status(:ok)
  end

  it "blocks scanner probes for secrets/dotfiles at the middleware" do
    get "/api/.env"
    expect(response).to have_http_status(:forbidden)
    expect(response.body).to eq("403 Forbidden\n")

    get "/wp-login.php"
    expect(response).to have_http_status(:forbidden)
  end

  it "escalates to a full ban after repeated probes from the same IP" do
    4.times { get "/api/.env" } # exceeds maxretry (3), banning the IP for bantime

    # Once banned, even an otherwise-innocuous path from that IP is blocked.
    get "/some-normal-looking-page"
    expect(response).to have_http_status(:forbidden)
  end

  it "throttles an IP hammering paths outside the known routes" do
    20.times { get "/no-such-page" }
    expect(response).not_to have_http_status(:too_many_requests)

    get "/no-such-page"
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).to eq("429 Too Many Requests\n")
  end
end
