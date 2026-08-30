require "rails_helper"

RSpec.describe "Admin Mastodon connection", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:redirect_uri) { "http://www.example.com/connected-apps/mastodon/callback" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    $redis.del(MastodonCredentials::REDIS_KEY, Admin::MastodonController::STATE_CACHE_KEY)
  end

  after { $redis.del(MastodonCredentials::REDIS_KEY, Admin::MastodonController::STATE_CACHE_KEY) }

  def sign_in! = sign_in_as(email: owner_email)

  def register_client!
    MastodonCredentials.store_client(
      instance: "mastodon.social", client_id: "client-id", client_secret: "client-secret",
      redirect_uri: redirect_uri
    )
  end

  describe "GET /connected-apps/mastodon" do
    before { sign_in! }

    it "renders the form" do
      get "/connected-apps/mastodon"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="instance"')
    end

    # ⚠️ Use a Web Awesome component in place of a native element, as in each other admin page.
    it "uses Web Awesome controls rather than native ones" do
      get "/connected-apps/mastodon"

      expect(response.body).to include("<wa-input")
      expect(response.body).to include("<wa-button type=\"submit\"")
      expect(response.body).not_to include("<button")
    end

    # ⚠️ The form redirects to another origin, and Turbo Drive cannot follow that.
    it "opts the form out of Turbo" do
      get "/connected-apps/mastodon"

      expect(response.body).to include('data-turbo="false"')
    end

    it "never lets the page be stored" do
      get "/connected-apps/mastodon"

      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    context "when an account is connected" do
      before do
        register_client!
        MastodonCredentials.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")
      end

      it "names the account and prefills the instance" do
        get "/connected-apps/mastodon"

        expect(response.body).to include("mastodon.social")
        expect(response.body).to include("@me@mastodon.social")
      end

      it "never renders the stored token" do
        get "/connected-apps/mastodon"

        expect(response.body).not_to include("an-access-token")
      end
    end
  end

  describe "POST /connected-apps/mastodon" do
    before { sign_in! }

    context "when the instance accepts the registration" do
      before do
        allow_any_instance_of(Mastodon).to receive(:register!) do
          register_client!
          true
        end
      end

      it "sends the owner to the instance to authorize" do
        post "/connected-apps/mastodon", params: { instance: "mastodon.social" }

        expect(response).to have_http_status(:found)
        expect(response.location).to start_with("https://mastodon.social/oauth/authorize?")
      end

      # ⚠️ The callback compares this value. Without it, anybody could give this app a code.
      it "issues a one-time state and carries it in the URL" do
        post "/connected-apps/mastodon", params: { instance: "mastodon.social" }

        state = $redis.get(Admin::MastodonController::STATE_CACHE_KEY)
        expect(state).to be_present
        expect(response.location).to include("state=#{state}")
      end

      it "registers with the callback of this host, and not a hardcoded one" do
        expect_any_instance_of(Mastodon).to receive(:register!)
          .with(instance: "mastodon.social", redirect_uri: redirect_uri)
          .and_return(true)
        allow_any_instance_of(Mastodon).to receive(:authorization_url).and_return("https://mastodon.social/oauth/authorize")

        post "/connected-apps/mastodon", params: { instance: "mastodon.social" }
      end
    end

    it "re-renders the form when the value cannot be an instance" do
      post "/connected-apps/mastodon", params: { instance: "not a host" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("admin.mastodon.flash.not_an_instance")))
    end

    it "re-renders the form when the instance refuses the registration" do
      allow_any_instance_of(Mastodon).to receive(:register!).and_return(false)

      post "/connected-apps/mastodon", params: { instance: "mastodon.social" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("admin.mastodon.flash.refused", instance: "mastodon.social")))
      expect(MastodonCredentials.connected?).to be(false)
    end
  end

  describe "GET /connected-apps/mastodon/callback" do
    before do
      sign_in!
      register_client!
      $redis.setex(Admin::MastodonController::STATE_CACHE_KEY, 600, "the-state")
    end

    it "exchanges the code and returns to the Connected apps page" do
      expect_any_instance_of(Mastodon).to receive(:connect!).with("a-code").and_return(true)

      get "/connected-apps/mastodon/callback", params: { code: "a-code", state: "the-state" }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.mastodon.flash.connected"))
    end

    it "spends the state, thus a replay cannot connect again" do
      allow_any_instance_of(Mastodon).to receive(:connect!).and_return(true)

      get "/connected-apps/mastodon/callback", params: { code: "a-code", state: "the-state" }

      expect($redis.get(Admin::MastodonController::STATE_CACHE_KEY)).to be_nil
    end

    it "refuses a code with the wrong state" do
      expect_any_instance_of(Mastodon).not_to receive(:connect!)

      get "/connected-apps/mastodon/callback", params: { code: "a-code", state: "another-state" }

      expect(response).to redirect_to("/connected-apps/mastodon")
      expect(flash[:alert]).to include(ERB::Util.html_escape(I18n.t("admin.oauth.invalid_state")))
    end

    it "sends the owner back to the form when the instance denied the app" do
      get "/connected-apps/mastodon/callback", params: { error: "access_denied", state: "the-state" }

      expect(response).to redirect_to("/connected-apps/mastodon")
      expect(flash[:alert]).to include("access_denied")
    end

    it "sends the owner back to the form when the exchange fails" do
      allow_any_instance_of(Mastodon).to receive(:connect!).and_return(false)

      get "/connected-apps/mastodon/callback", params: { code: "a-code", state: "the-state" }

      expect(response).to redirect_to("/connected-apps/mastodon")
      expect(flash[:alert]).to eq(I18n.t("admin.mastodon.flash.no_token"))
    end
  end

  describe "DELETE /connected-apps/mastodon" do
    before do
      sign_in!
      register_client!
      MastodonCredentials.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")
    end

    it "forgets the connection and returns to the page" do
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200, body: "{}", request: nil)
      )

      delete "/connected-apps/mastodon"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.mastodon.flash.disconnected"))
      expect(MastodonCredentials.connected?).to be(false)
    end
  end

  describe "without an owner session" do
    it "redirects the form to the login screen" do
      get "/connected-apps/mastodon"

      expect(response).to redirect_to("/signin")
    end

    it "refuses to start a connection" do
      expect_any_instance_of(Mastodon).not_to receive(:register!)

      post "/connected-apps/mastodon", params: { instance: "mastodon.social" }

      expect(response).to redirect_to("/signin")
    end

    # ⚠️ The owner session gates the callback, and the state value gates it a second time. Mastodon
    # redirects the browser of the owner, and that browser has the session.
    it "refuses the callback" do
      expect_any_instance_of(Mastodon).not_to receive(:connect!)

      get "/connected-apps/mastodon/callback", params: { code: "a-code", state: "the-state" }

      expect(response).to redirect_to("/signin")
    end

    it "refuses to disconnect" do
      register_client!
      MastodonCredentials.store_token(access_token: "an-access-token", handle: "@me@mastodon.social")

      delete "/connected-apps/mastodon"

      expect(response).to redirect_to("/signin")
      expect(MastodonCredentials.connected?).to be(true)
    end
  end
end
