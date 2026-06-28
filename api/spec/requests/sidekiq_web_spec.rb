require "rails_helper"

# Guards the security-critical wiring: the Sidekiq web UI must never be reachable without the
# owner session. The Rack guard redirects unauthenticated hits to /login before any Redis access,
# so this needs no running Redis. (The authenticated render reads from Redis and isn't exercised.)
RSpec.describe "Sidekiq::Web mount", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return("owner@example.com")
  end

  it "redirects to /login without an owner session" do
    get "/sidekiq"
    expect(response).to redirect_to("/login")
  end
end
