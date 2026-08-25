require "rails_helper"

RSpec.describe "Admin republish", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:owner_email) { "owner@example.com" }
  let(:quarantine) { instance_double(SpamQuarantine, count: 0) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')
    allow(SpamQuarantine).to receive(:new).and_return(quarantine)
    # The lock is free unless an example says that it is not.
    allow($redis).to receive(:set).and_return(true)
  end

  def sign_in!
    sign_in_as(email: owner_email)
  end

  describe "the nav item and the dialog" do
    before { sign_in! }

    it "opens the dialog instead of going to a page" do
      get "/"

      trigger = response.body.scan(/<wa-button\b[^>]*>/).find { |tag| tag.include?('data-dialog="open republish-site"') }
      expect(trigger).to be_present
      expect(trigger).not_to include("href=")
      # The drawer of a mobile screen must close behind the dialog.
      expect(trigger).to include('data-drawer="close"')
    end

    it "renders the dialog and its form once, on every admin page" do
      allow(quarantine).to receive(:all).and_return([])

      get "/spam"

      expect(response.body.scan('id="republish-site"').length).to eq(1)
      expect(response.body).to match(%r{<form[^>]*action="/republish"})
      expect(response.body).to include('form="republish-form"')
      # One control, and no radio group: a delay of zero is "now".
      expect(response.body).to include('<wa-number-input name="minutes"')
      expect(response.body).not_to include("<wa-radio")
      # wa-button renders its own button in a shadow root, thus no code here has a native one.
      expect(response.body).not_to include("<button")
    end
  end

  describe "POST /republish" do
    before { sign_in! }

    it "builds now for a delay of zero, and takes the shared lock" do
      expect($redis).to receive(:set).with("build:trigger_lock", "1", nx: true, ex: 60).and_return(true)

      post "/republish", params: { minutes: "0" }

      expect(SiteBuildJob).to have_enqueued_sidekiq_job("admin-republish")
      expect(SiteBuildJob.jobs.first["at"]).to be_nil
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/")
      expect(flash[:notice]).to include("now")
    end

    it "goes back to the page that opened the dialog" do
      post "/republish", params: { minutes: "0" }, headers: { "HTTP_REFERER" => "http://www.example.com/spam" }

      expect(response).to redirect_to("http://www.example.com/spam")
    end

    it "queues nothing while another build holds the lock" do
      allow($redis).to receive(:set).and_return(false)

      post "/republish", params: { minutes: "0" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("already started")
    end

    # ⚠️ The lock comes first. In the other order, a click inside the window of the lock would
    # cancel the scheduled build and start nothing.
    it "keeps the scheduled build when the lock refuses an immediate one" do
      allow($redis).to receive(:set).and_return(false)
      expect(SiteBuildJob).not_to receive(:cancel_scheduled)

      post "/republish", params: { minutes: "0" }
    end

    it "schedules a build after the number of minutes the owner picked" do
      travel_to Time.utc(2026, 8, 24, 12, 0, 0) do
        post "/republish", params: { minutes: "15" }
      end

      expect(SiteBuildJob).to have_enqueued_sidekiq_job("admin-republish").at(Time.utc(2026, 8, 24, 12, 15, 0))
      expect(flash[:notice]).to include("scheduled in 15 minutes")
    end

    it "says one minute in the singular" do
      post "/republish", params: { minutes: "1" }

      expect(flash[:notice]).to include("in 1 minute.")
    end

    it "says that it replaced the build that was scheduled" do
      allow(SiteBuildJob).to receive(:schedule_in).and_return(true)

      post "/republish", params: { minutes: "10" }

      expect(flash[:notice]).to include("rescheduled")
    end

    it "says that an immediate build cancelled the one that was scheduled" do
      allow(SiteBuildJob).to receive(:cancel_scheduled).and_return(true)

      post "/republish", params: { minutes: "0" }

      expect(flash[:notice]).to include("cancelled")
    end

    it "refuses a number of minutes above the maximum" do
      post "/republish", params: { minutes: "61" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("between 0 and 60 minutes")
    end

    it "refuses a negative number" do
      post "/republish", params: { minutes: "-1" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("between 0 and 60 minutes")
    end

    # ⚠️ `to_i` reads "5.9" as 5 and "soon" as 0, and 0 starts a build.
    it "refuses a value that is not a whole number" do
      post "/republish", params: { minutes: "5.9" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("between 0 and 60 minutes")
    end

    it "refuses a value that is not a number" do
      post "/republish", params: { minutes: "soon" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("between 0 and 60 minutes")
    end

    it "refuses a value that is absent" do
      post "/republish", params: {}

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("between 0 and 60 minutes")
    end
  end

  describe "without an owner session" do
    it "refuses to start a build" do
      post "/republish", params: { minutes: "0" }

      expect(response).to redirect_to("/signin")
      expect(SiteBuildJob.jobs).to be_empty
    end
  end
end
