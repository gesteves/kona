require "rails_helper"

RSpec.describe "Admin TrainerRoad connection", type: :request do
  include_context "the admin UI"
  let(:url) { "https://www.trainerroad.com/app/calendar/00000000-0000-4000-8000-000000000000" }
  let(:calendar) { "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\nEND:VCALENDAR" }

  before do
    $redis.del(TrainerRoadCredentials::REDIS_KEY)
  end

  def sign_in! = sign_in_as(email: owner_email)

  def stub_feed(success: true, body: nil)
    allow(HTTParty).to receive(:get).and_return(
      instance_double(HTTParty::Response, success?: success, code: success ? 200 : 404, body: body || calendar)
    )
  end

  describe "GET /connected-apps/trainerroad" do
    before { sign_in! }

    it "renders the form" do
      get "/connected-apps/trainerroad"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="calendar_url"')
    end

    # ⚠️ Use a Web Awesome component in place of a native element, as in each other admin page.
    it "uses Web Awesome controls rather than native ones" do
      get "/connected-apps/trainerroad"

      expect(response.body).to include("<wa-input")
      expect(response.body).to include("<wa-button type=\"submit\"")
      expect(response.body).not_to include("<button")
    end

    it "never lets the page be stored" do
      get "/connected-apps/trainerroad"

      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    context "when a URL is already stored" do
      before { TrainerRoadCredentials.store(calendar_url: url) }

      # ⚠️ The GUID at the end of the URL is the credential, thus the page says only that a URL
      # exists.
      it "says a URL is saved but never renders it" do
        get "/connected-apps/trainerroad"

        expect(response.body).to include(I18n.t("admin.trainer_road.show.calendar_url_hint"))
        expect(response.body).not_to include("00000000-0000-4000-8000-000000000000")
      end
    end

    context "when nothing is stored" do
      it "does not claim a URL is saved" do
        get "/connected-apps/trainerroad"

        expect(response.body).not_to include(I18n.t("admin.trainer_road.show.calendar_url_hint"))
      end
    end
  end

  describe "POST /connected-apps/trainerroad" do
    before { sign_in! }

    # ⚠️ The code gets the feed and parses it. A URL with a typing error, stored with no check,
    # makes the rest-day check and the planned-workout line fail with no message.
    context "when the URL gives a calendar" do
      before { stub_feed }

      it "stores it and returns to the Connected apps page" do
        post "/connected-apps/trainerroad", params: { calendar_url: url }

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to("/connected-apps")
        expect(flash[:notice]).to eq(I18n.t("admin.trainer_road.flash.connected"))
        expect(TrainerRoadCredentials.fetch).to eq(url)
      end

      it "trims a URL that was pasted with whitespace" do
        post "/connected-apps/trainerroad", params: { calendar_url: "  #{url}  " }

        expect(TrainerRoadCredentials.fetch).to eq(url)
      end
    end

    context "when the URL gives no calendar" do
      before { stub_feed(success: true, body: "<html>Sign in</html>") }

      it "stores nothing and re-renders the form with an error" do
        post "/connected-apps/trainerroad", params: { calendar_url: url }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(ERB::Util.html_escape(I18n.t("admin.trainer_road.flash.refused")))
        expect(TrainerRoadCredentials.stored?).to be(false)
      end

      it "does not echo the rejected URL back into the form" do
        post "/connected-apps/trainerroad", params: { calendar_url: url }

        expect(response.body).not_to include("00000000-0000-4000-8000-000000000000")
      end
    end

    it "stores nothing when the field is empty" do
      post "/connected-apps/trainerroad", params: { calendar_url: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(TrainerRoadCredentials.stored?).to be(false)
    end
  end

  describe "DELETE /connected-apps/trainerroad" do
    before do
      sign_in!
      TrainerRoadCredentials.store(calendar_url: url)
    end

    it "forgets the stored URL and returns to the page" do
      delete "/connected-apps/trainerroad"

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/connected-apps")
      expect(flash[:notice]).to eq(I18n.t("admin.trainer_road.flash.disconnected"))
      expect(TrainerRoadCredentials.stored?).to be(false)
    end
  end

  describe "without a session" do
    it "sends each action to the sign-in page" do
      get "/connected-apps/trainerroad"
      expect(response).to redirect_to("/signin")

      post "/connected-apps/trainerroad", params: { calendar_url: url }
      expect(response).to redirect_to("/signin")

      delete "/connected-apps/trainerroad"
      expect(response).to redirect_to("/signin")
    end
  end
end
