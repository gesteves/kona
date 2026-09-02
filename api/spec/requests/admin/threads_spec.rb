require "rails_helper"

RSpec.describe "Admin Threads connection", type: :request do
  let(:owner_email) { "owner@example.com" }
  let(:redirect_uri) { "http://www.example.com/connected-apps/threads/callback" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow(ENV).to receive(:[]).with("THREADS_APP_ID").and_return("app-id")
    allow(ENV).to receive(:[]).with("THREADS_APP_SECRET").and_return("app-secret")
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    $redis.del(ThreadsCredentials::REDIS_KEY)
  end

  after { $redis.del(ThreadsCredentials::REDIS_KEY) }

  def sign_in! = sign_in_as(email: owner_email)

  def connect!
    ThreadsCredentials.store_account(
      access_token: "a-long-lived-token", expires_in: 60.days.to_i,
      user_id: "12345", username: "me"
    )
  end

  describe "GET /connected-apps/threads/authorize" do
    before { sign_in! }

    it "sends the owner to Threads to authorize" do
      get "/connected-apps/threads/authorize"

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://threads.net/oauth/authorize?")
    end

    # ⚠️ The callback compares this value. Without it, anybody could give this app a code.
    it "issues a one-time state and carries it in the URL" do
      get "/connected-apps/threads/authorize"

      state = session["threads_oauth_state"]["value"]
      expect(state).to be_present
      expect(response.location).to include("state=#{state}")
    end

    # ⚠️ The callback URL follows the request host, thus it always names the admin host and no
    # environment variable can name the wrong one.
    it "asks for a callback on the host of the request" do
      get "/connected-apps/threads/authorize"

      expect(response.location).to include(CGI.escape(redirect_uri))
    end

    it "says so when the Meta app credentials are missing" do
      allow(ENV).to receive(:[]).with("THREADS_APP_ID").and_return(nil)

      get "/connected-apps/threads/authorize"

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to include(ERB::Util.html_escape(I18n.t("admin.threads.flash.unconfigured")))
    end
  end

  describe "GET /connected-apps/threads/callback" do
    before { sign_in! }

    # The state that Meta must send back. The flow puts it in the session.
    # @return [String]
    let(:the_state) do
      get "/connected-apps/threads/authorize"
      session["threads_oauth_state"]["value"]
    end

    it "exchanges the code and returns to the Connected apps page" do
      expect_any_instance_of(Threads).to receive(:connect!)
        .with("a-code", redirect_uri: redirect_uri).and_return(true)

      get "/connected-apps/threads/callback", params: { code: "a-code", state: the_state }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.threads.flash.connected"))
    end

    it "spends the state, thus a replay cannot connect again" do
      allow_any_instance_of(Threads).to receive(:connect!).and_return(true)

      get "/connected-apps/threads/callback", params: { code: "a-code", state: the_state }
      get "/connected-apps/threads/callback", params: { code: "a-code", state: the_state }

      expect(flash[:alert]).to include(ERB::Util.html_escape(I18n.t("admin.oauth.invalid_state")))
    end

    it "keeps the state after a failed exchange, thus the owner can try again" do
      # Each request makes a new Threads, thus the answers are counted here and not on one instance.
      attempts = 0
      allow_any_instance_of(Threads).to receive(:connect!) { (attempts += 1) > 1 }

      get "/connected-apps/threads/callback", params: { code: "a-code", state: the_state }
      get "/connected-apps/threads/callback", params: { code: "a-code", state: the_state }

      expect(response).to redirect_to("/connected-apps")
    end

    it "refuses a code with the wrong state" do
      expect_any_instance_of(Threads).not_to receive(:connect!)

      get "/connected-apps/threads/callback", params: { code: "a-code", state: "another-state" }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to include(ERB::Util.html_escape(I18n.t("admin.oauth.invalid_state")))
    end

    it "sends the owner back when Meta denied the app" do
      get "/connected-apps/threads/callback",
          params: { error: "access_denied", error_description: "The user denied the request", state: the_state }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to include("denied the request")
    end

    it "sends the owner back when the exchange fails" do
      allow_any_instance_of(Threads).to receive(:connect!).and_return(false)

      get "/connected-apps/threads/callback", params: { code: "a-code", state: the_state }

      expect(response).to redirect_to("/connected-apps")
      expect(flash[:alert]).to eq(I18n.t("admin.threads.flash.no_token"))
    end
  end

  describe "DELETE /connected-apps/threads" do
    before do
      sign_in!
      connect!
    end

    it "forgets the connection and returns to the page" do
      delete "/connected-apps/threads"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.threads.flash.disconnected"))
      expect(ThreadsCredentials.connected?).to be(false)
    end
  end

  describe "without an owner session" do
    it "refuses to start a connection" do
      get "/connected-apps/threads/authorize"

      expect(response).to redirect_to("/signin")
    end

    # ⚠️ The owner session gates the callback, and the state value gates it a second time.
    it "refuses the callback" do
      expect_any_instance_of(Threads).not_to receive(:connect!)

      get "/connected-apps/threads/callback", params: { code: "a-code", state: "the-state" }

      expect(response).to redirect_to("/signin")
    end

    it "refuses to disconnect" do
      connect!

      delete "/connected-apps/threads"

      expect(response).to redirect_to("/signin")
      expect(ThreadsCredentials.connected?).to be(true)
    end
  end
end
