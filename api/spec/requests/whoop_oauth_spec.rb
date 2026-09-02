require "rails_helper"

RSpec.describe "Whoop OAuth", type: :request do
  include ActiveSupport::Testing::TimeHelpers

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
        allow_any_instance_of(Whoop).to receive(:get_authorization_url) do |_whoop, state|
          "https://api.prod.whoop.com/oauth/oauth2/auth?state=#{state}"
        end
      end

      it "keeps a one-time state in the session and redirects to Whoop with it" do
        get "/whoop/auth"

        expect(response).to have_http_status(:redirect)
        expect(response.location).to start_with("https://api.prod.whoop.com/oauth/oauth2/auth")
        state = session["whoop_oauth_state"]["value"]
        expect(state).to be_present
        expect(response.location).to end_with("state=#{state}")
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
    let(:owner_email) { "owner@example.com" }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
      allow_any_instance_of(Whoop).to receive(:get_authorization_url) do |_whoop, state|
        "https://api.prod.whoop.com/oauth/oauth2/auth?state=#{state}"
      end
    end

    # Starts the flow as the owner and gives the state that Whoop must send back.
    # @return [String]
    def issue_state!
      sign_in_as(email: owner_email)
      get "/whoop/auth"
      session["whoop_oauth_state"]["value"]
    end

    it "rejects a missing or mismatched state" do
      get "/whoop/callback", params: { code: "abc", state: "whatever" }
      expect(response).to have_http_status(:unprocessable_content)

      issue_state!
      get "/whoop/callback", params: { code: "abc", state: "another" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    # ⚠️ The state is in the session of the browser that started the flow. A state that another
    # browser reads from a URL is of no use without that session.
    it "rejects the state from another browser session" do
      state = issue_state!
      reset!

      get "/whoop/callback", params: { code: "abc", state: state }

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects the callback when Whoop reports an error, before touching the state" do
      get "/whoop/callback", params: { error: "access_denied", state: "anything" }

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("access_denied")
    end

    it "exchanges the code when the state matches, then spends the state" do
      state = issue_state!
      allow_any_instance_of(Whoop).to receive(:exchange_code_for_tokens).with("abc").and_return({ access_token: "x" })

      get "/whoop/callback", params: { code: "abc", state: state }

      # The browser goes back to the admin page that started the flow, thus its status badge shows
      # the new state.
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq("Whoop connected.")

      get "/whoop/callback", params: { code: "abc", state: state }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 502 when the code exchange fails, and keeps the state for another attempt" do
      state = issue_state!
      # Each request makes a new Whoop, thus the answers are counted here and not on one instance.
      attempts = 0
      allow_any_instance_of(Whoop).to receive(:exchange_code_for_tokens).with("abc") do
        (attempts += 1) == 1 ? nil : { access_token: "x" }
      end

      get "/whoop/callback", params: { code: "abc", state: state }
      expect(response).to have_http_status(:bad_gateway)
      expect(response.body).to include("Failed to exchange")

      get "/whoop/callback", params: { code: "abc", state: state }
      expect(response).to redirect_to("/connected-apps")
    end

    it "rejects a state that is too old" do
      state = issue_state!
      travel_to(OauthState::STATE_TTL.from_now + 1.minute) do
        get "/whoop/callback", params: { code: "abc", state: state }
      end

      expect(response).to have_http_status(:unprocessable_content)
    end

    # ⚠️ The query string of the callback has the authorization `code` and the `state`, which works
    # one time. Thus a browser and each server between must not store it. That is why this controller
    # uses OwnerFacing: it has no admin layout that could give that instruction.
    it "is never stored or indexed, even on the error paths" do
      get "/whoop/callback", params: { error: "access_denied", state: "anything" }

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
    end
  end
end
