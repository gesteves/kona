require "rails_helper"

RSpec.describe "Admin Strava connection", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:redirect_uri) { "http://www.example.com/connected-apps/strava/callback" }
  let(:scope) { "read,activity:read_all,activity:write" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("STRAVA_CLIENT_ID").and_return("client-id")
    allow(ENV).to receive(:[]).with("STRAVA_CLIENT_SECRET").and_return("client-secret")
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    $redis.del(StravaCredentials::REDIS_KEY)
  end

  def sign_in! = sign_in_as(email: owner_email)

  def connect!
    StravaCredentials.store_athlete(
      athlete_id: 42, athlete_name: "Athlete",
      access_token: "an-access-token", refresh_token: "a-refresh-token", expires_at: 6.hours.from_now.to_i
    )
  end

  describe "GET /connected-apps/strava/authorize" do
    before { sign_in! }

    it "sends the owner to Strava with a one-time state and the callback of the request" do
      get "/connected-apps/strava/authorize"

      state = session["strava_oauth_state"]["value"]
      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://www.strava.com/oauth/authorize?")
      expect(response.location).to include("state=#{state}")
      expect(response.location).to include(CGI.escape(redirect_uri))
    end

    it "says so when the Strava app credentials are missing" do
      allow(ENV).to receive(:[]).with("STRAVA_CLIENT_ID").and_return(nil)

      get "/connected-apps/strava/authorize"

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.strava.flash.unconfigured"))
    end
  end

  describe "GET /connected-apps/strava/callback" do
    before { sign_in! }

    let(:the_state) do
      get "/connected-apps/strava/authorize"
      session["strava_oauth_state"]["value"]
    end

    it "exchanges the code and returns to the Connected apps page" do
      expect_any_instance_of(Strava).to receive(:connect!).with("a-code").and_return(true)

      get "/connected-apps/strava/callback", params: { code: "a-code", state: the_state, scope: scope }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.strava.flash.connected"))
    end

    it "spends the state, thus a replay cannot connect again" do
      allow_any_instance_of(Strava).to receive(:connect!).and_return(true)

      get "/connected-apps/strava/callback", params: { code: "a-code", state: the_state, scope: scope }
      get "/connected-apps/strava/callback", params: { code: "a-code", state: the_state, scope: scope }

      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))
    end

    it "refuses a code with the wrong state" do
      expect_any_instance_of(Strava).not_to receive(:connect!)

      get "/connected-apps/strava/callback", params: { code: "a-code", state: "another-state", scope: scope }

      expect(flash[:alert]).to eq(I18n.t("admin.oauth.invalid_state"))
    end

    # ⚠️ The athlete can clear a scope on the Strava screen, and that token cannot edit an activity.
    it "refuses a connection without the write scope" do
      expect_any_instance_of(Strava).not_to receive(:connect!)

      get "/connected-apps/strava/callback", params: { code: "a-code", state: the_state, scope: "read,activity:read_all" }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.strava.flash.missing_scope"))
    end

    it "sends the owner back when Strava denied the app" do
      get "/connected-apps/strava/callback", params: { error: "access_denied", state: the_state }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.strava.flash.unauthorized", error: "access_denied"))
    end

    it "sends the owner back when the exchange fails" do
      allow_any_instance_of(Strava).to receive(:connect!).and_return(false)

      get "/connected-apps/strava/callback", params: { code: "a-code", state: the_state, scope: scope }

      expect(flash[:alert]).to eq(I18n.t("admin.strava.flash.no_token"))
    end
  end

  describe "DELETE /connected-apps/strava" do
    before do
      sign_in!
      connect!
      allow(HTTParty).to receive(:post)
    end

    it "forgets the connection and returns to the page" do
      delete "/connected-apps/strava"

      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq(I18n.t("admin.strava.flash.disconnected"))
      expect(StravaCredentials.connected?).to be(false)
    end
  end

  describe "without an owner session" do
    it "refuses to start a connection" do
      get "/connected-apps/strava/authorize"

      expect(response).to redirect_to("/signin")
    end

    it "refuses the callback" do
      expect_any_instance_of(Strava).not_to receive(:connect!)

      get "/connected-apps/strava/callback", params: { code: "a-code", state: "the-state", scope: scope }

      expect(response).to redirect_to("/signin")
    end

    it "refuses to disconnect" do
      connect!

      delete "/connected-apps/strava"

      expect(response).to redirect_to("/signin")
      expect(StravaCredentials.connected?).to be(true)
    end
  end
end
