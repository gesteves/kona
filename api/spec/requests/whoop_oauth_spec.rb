require "rails_helper"

RSpec.describe "Whoop OAuth", type: :request do
  describe "GET /whoop/auth" do
    it "requires HTTP Basic Auth" do
      get "/whoop/auth"
      expect(response).to have_http_status(:unauthorized)
    end

    context "with valid credentials" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("WHOOP_AUTH_USERNAME").and_return("owner")
        allow(ENV).to receive(:[]).with("WHOOP_AUTH_PASSWORD").and_return("secret")
        allow($redis).to receive(:setex)
        allow_any_instance_of(Whoop).to receive(:get_authorization_url).and_return("https://api.prod.whoop.com/oauth/oauth2/auth?x=1")
      end

      it "stores a state and redirects to Whoop" do
        expect($redis).to receive(:setex).with("whoop:oauth:state", 10.minutes, anything)

        get "/whoop/auth", headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("owner", "secret") }

        expect(response).to have_http_status(:redirect)
        expect(response.location).to start_with("https://api.prod.whoop.com/oauth/oauth2/auth")
      end
    end
  end

  describe "GET /whoop/callback" do
    it "rejects a missing or mismatched state" do
      allow($redis).to receive(:get).with("whoop:oauth:state").and_return(nil)

      get "/whoop/callback", params: { code: "abc", state: "whatever" }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "exchanges the code when the state matches" do
      allow($redis).to receive(:get).with("whoop:oauth:state").and_return("good-state")
      allow($redis).to receive(:del)
      allow_any_instance_of(Whoop).to receive(:exchange_code_for_tokens).with("abc").and_return({ access_token: "x" })

      get "/whoop/callback", params: { code: "abc", state: "good-state" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Whoop connected")
    end
  end
end
