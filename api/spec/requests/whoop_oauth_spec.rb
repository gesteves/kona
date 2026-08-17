require "rails_helper"

RSpec.describe "Whoop OAuth", type: :request do
  describe "GET /whoop/auth" do
    let(:owner_email) { "owner@example.com" }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    end

    it "redirects to the login page when not signed in" do
      get "/whoop/auth"
      expect(response).to redirect_to("/signin")
    end

    context "when signed in as the owner" do
      before do
        sign_in_as(email: owner_email)
        allow($redis).to receive(:setex)
        allow_any_instance_of(Whoop).to receive(:get_authorization_url).and_return("https://api.prod.whoop.com/oauth/oauth2/auth?x=1")
      end

      it "stores a state and redirects to Whoop" do
        expect($redis).to receive(:setex).with("whoop:oauth:state", 10.minutes, anything)

        get "/whoop/auth"

        expect(response).to have_http_status(:redirect)
        expect(response.location).to start_with("https://api.prod.whoop.com/oauth/oauth2/auth")
      end

      it "returns 503 when Whoop OAuth isn't configured" do
        allow_any_instance_of(Whoop).to receive(:get_authorization_url).and_return(nil)

        get "/whoop/auth"

        expect(response).to have_http_status(:service_unavailable)
        expect(response.body).to include("not configured")
      end
    end
  end

  describe "GET /whoop/callback" do
    it "rejects a missing or mismatched state" do
      allow($redis).to receive(:get).with("whoop:oauth:state").and_return(nil)

      get "/whoop/callback", params: { code: "abc", state: "whatever" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects the callback when Whoop reports an error, before touching the state" do
      get "/whoop/callback", params: { error: "access_denied", state: "anything" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("access_denied")
    end

    it "exchanges the code when the state matches" do
      allow($redis).to receive(:get).with("whoop:oauth:state").and_return("good-state")
      allow($redis).to receive(:del)
      allow_any_instance_of(Whoop).to receive(:exchange_code_for_tokens).with("abc").and_return({ access_token: "x" })

      get "/whoop/callback", params: { code: "abc", state: "good-state" }

      # Back to the admin page the flow started from, so its status badge reflects the new state.
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq("Whoop connected.")
    end

    it "returns 502 when the code exchange fails" do
      allow($redis).to receive(:get).with("whoop:oauth:state").and_return("good-state")
      allow($redis).to receive(:del)
      allow_any_instance_of(Whoop).to receive(:exchange_code_for_tokens).with("abc").and_return(nil)

      get "/whoop/callback", params: { code: "abc", state: "good-state" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.body).to include("Failed to exchange")
    end

    # ⚠️ The callback's query string carries the authorization `code` and the one-time `state`, so
    # neither a browser nor an intermediary may store it. This is what OwnerFacing is on this
    # controller for — it has no admin layout of its own to carry the signal.
    it "is never stored or indexed, even on the error paths" do
      get "/whoop/callback", params: { error: "access_denied", state: "anything" }

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
    end
  end
end
