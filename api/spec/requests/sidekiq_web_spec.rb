require "rails_helper"

# Guards the security-critical wiring: the Sidekiq web UI must never be reachable without the
# owner credentials. These cases are rejected by Rack::Auth::Basic before any Redis access, so
# they need no running Redis. (The authenticated success path renders from Redis and isn't
# exercised here.)
RSpec.describe "Sidekiq::Web mount", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WHOOP_AUTH_USERNAME").and_return("owner")
    allow(ENV).to receive(:[]).with("WHOOP_AUTH_PASSWORD").and_return("secret")
  end

  it "returns 401 without credentials" do
    get "/sidekiq"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns 401 with wrong credentials" do
    creds = ActionController::HttpAuthentication::Basic.encode_credentials("owner", "nope")
    get "/sidekiq", headers: { "Authorization" => creds }
    expect(response).to have_http_status(:unauthorized)
  end
end
