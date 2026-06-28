require "rails_helper"

RSpec.describe "Owner sessions", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
  end

  describe "GET /login" do
    it "renders the Google sign-in button" do
      get "/login"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Sign in with Google")
    end
  end

  describe "the OAuth callback" do
    it "signs in the owner (verified, matching email) and redirects to the dashboard" do
      sign_in_as(email: owner_email)
      expect(response).to redirect_to("/sidekiq")
    end

    it "returns the owner to the page they were headed to before signing in" do
      get "/whoop/auth" # unauthenticated → stashes return_to, redirects to /login
      expect(response).to redirect_to("/login")

      sign_in_as(email: owner_email)
      expect(response).to redirect_to("/whoop/auth")
    end

    it "rejects a non-owner email with 403 and no session" do
      sign_in_as(email: "someone-else@example.com")
      expect(response).to have_http_status(:forbidden)

      get "/whoop/auth"
      expect(response).to redirect_to("/login")
    end

    it "rejects an unverified email with 403" do
      sign_in_as(email: owner_email, verified: false)
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects when OWNER_EMAIL is not configured" do
      allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(nil)
      sign_in_as(email: owner_email)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /logout" do
    it "clears the owner session" do
      sign_in_as(email: owner_email)
      post "/logout"
      expect(response).to redirect_to("/login")

      get "/whoop/auth"
      expect(response).to redirect_to("/login")
    end
  end
end
