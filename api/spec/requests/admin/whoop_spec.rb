require "rails_helper"

RSpec.describe "Admin Whoop connection", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(Whoop).to receive(:authorization_url) do |_whoop, state|
      "https://api.prod.whoop.com/oauth/oauth2/auth?state=#{state}"
    end
  end

  def sign_in! = sign_in_as(email: owner_email)

  # Starts the flow as the owner and gives the state that Whoop must send back.
  # @return [String]
  def issue_state!
    sign_in!
    get "/whoop/auth"
    session["whoop_oauth_state"]["value"]
  end

  describe "GET /whoop/auth" do
    it "redirects to the login page when not signed in" do
      get "/whoop/auth"

      expect(response).to redirect_to("/signin")
    end

    it "keeps a one-time state in the session and redirects to Whoop with it" do
      sign_in!

      get "/whoop/auth"

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://api.prod.whoop.com/oauth/oauth2/auth")
      state = session["whoop_oauth_state"]["value"]
      expect(state).to be_present
      expect(response.location).to end_with("state=#{state}")
    end

    it "says so when the Whoop app credentials are missing" do
      sign_in!
      allow_any_instance_of(Whoop).to receive(:authorization_url).and_return(nil)

      get "/whoop/auth"

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.whoop.flash.unconfigured"))
    end
  end

  describe "GET /whoop/callback" do
    # ⚠️ The callback is an admin page. Whoop redirects the browser of the owner to it, and that
    # browser has the session.
    it "redirects to the login page when not signed in, and exchanges nothing" do
      expect_any_instance_of(Whoop).not_to receive(:connect!)

      get "/whoop/callback", params: { code: "abc", state: "whatever" }

      expect(response).to redirect_to("/signin")
    end

    it "refuses a missing or mismatched state" do
      expect_any_instance_of(Whoop).not_to receive(:connect!)
      sign_in!

      get "/whoop/callback", params: { code: "abc", state: "whatever" }
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))

      issue_state!
      get "/whoop/callback", params: { code: "abc", state: "another" }
      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))
    end

    # ⚠️ The state is in the session of the browser that started the flow. A state that another
    # browser reads from a URL is of no use without that session.
    it "refuses the state from another browser session" do
      expect_any_instance_of(Whoop).not_to receive(:connect!)
      state = issue_state!
      reset!
      sign_in!

      get "/whoop/callback", params: { code: "abc", state: state }

      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))
    end

    it "says so when Whoop reports an error, before it reads the state" do
      sign_in!

      get "/whoop/callback", params: { error: "access_denied", state: "anything" }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.whoop.flash.unauthorized", error: "access_denied"))
    end

    it "exchanges the code when the state matches, then spends the state" do
      state = issue_state!
      allow_any_instance_of(Whoop).to receive(:connect!).with("abc").and_return({ access_token: "x" })

      get "/whoop/callback", params: { code: "abc", state: state }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.whoop.flash.connected"))

      get "/whoop/callback", params: { code: "abc", state: state }
      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))
    end

    # ⚠️ A failed exchange keeps the state, thus a short problem at Whoop does not send the owner
    # back to the start.
    it "says so when the code exchange fails, and keeps the state for another attempt" do
      state = issue_state!
      # Each request makes a new Whoop, thus the answers are counted here and not on one instance.
      attempts = 0
      allow_any_instance_of(Whoop).to receive(:connect!).with("abc") do
        (attempts += 1) == 1 ? nil : { access_token: "x" }
      end

      get "/whoop/callback", params: { code: "abc", state: state }
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.whoop.flash.no_token"))

      get "/whoop/callback", params: { code: "abc", state: state }
      expect(flash[:notice]).to eq(I18n.t("admin.whoop.flash.connected"))
    end

    it "refuses a state that is too old" do
      state = issue_state!
      travel_to(OauthState::STATE_TTL.from_now + 1.minute) do
        get "/whoop/callback", params: { code: "abc", state: state }
      end

      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))
    end

    # ⚠️ The query string of the callback has the authorization `code` and the `state`, which works
    # one time. Thus a browser and each server between must not store it.
    it "is never stored or indexed, even on the error paths" do
      sign_in!

      get "/whoop/callback", params: { error: "access_denied", state: "anything" }

      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
    end
  end

  describe "DELETE /connected-apps/whoop" do
    it "needs the owner session" do
      expect_any_instance_of(Whoop).not_to receive(:disconnect!)

      delete "/connected-apps/whoop"

      expect(response).to redirect_to("/signin")
    end

    it "forgets the stored credentials and returns to the page" do
      sign_in!
      expect_any_instance_of(Whoop).to receive(:disconnect!)

      delete "/connected-apps/whoop"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.whoop.flash.disconnected"))
    end
  end
end
