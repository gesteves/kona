require "rails_helper"

# The tests for a security rule: a visitor must never reach the Sidekiq web UI with no owner
# session. The Rack guard sends a request with no authentication to /signin before any Redis access,
# thus these tests need no Redis. The render with a session reads Redis, and no test covers it.
RSpec.describe "Sidekiq::Web mount", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return("owner@example.com")
  end

  it "redirects to /signin without an owner session" do
    get "/sidekiq"
    expect(response).to redirect_to("/signin")
  end
end
