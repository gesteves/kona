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
      # wa-button renders its own button in a shadow root, thus no code here has a native one.
      expect(response.body).not_to include("<button")
    end
  end

  describe "POST /republish" do
    before { sign_in! }

    it "builds now and takes the shared lock" do
      expect($redis).to receive(:set).with("build:trigger_lock", "1", nx: true, ex: 60).and_return(true)

      post "/republish", params: { schedule: "now" }

      expect(SiteBuildJob).to have_enqueued_sidekiq_job("admin-republish")
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to("/")
      expect(flash[:notice]).to include("now")
    end

    it "goes back to the page that opened the dialog" do
      post "/republish", params: { schedule: "now" }, headers: { "HTTP_REFERER" => "http://www.example.com/spam" }

      expect(response).to redirect_to("http://www.example.com/spam")
    end

    it "queues nothing while another build holds the lock" do
      allow($redis).to receive(:set).and_return(false)

      post "/republish", params: { schedule: "now" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("already started")
    end

    it "schedules a build at the time the owner picked, in the zone of their browser" do
      travel_to Time.utc(2026, 8, 24, 12, 0, 0) do
        post "/republish", params: {
          schedule: "later", date: "2026-08-25", time: "06:30", time_zone: "America/Los_Angeles"
        }
      end

      expect(SiteBuildJob).to have_enqueued_sidekiq_job("admin-republish").at(Time.utc(2026, 8, 25, 13, 30, 0))
      expect(flash[:notice]).to include("25 August 2026")
    end

    # ⚠️ The dialog can stay open past the time that the owner picked. That is not an error.
    it "builds now when the time it is given has passed" do
      travel_to Time.utc(2026, 8, 24, 12, 0, 0) do
        post "/republish", params: {
          schedule: "later", date: "2026-08-24", time: "11:58", time_zone: "UTC"
        }
      end

      expect(SiteBuildJob).to have_enqueued_sidekiq_job("admin-republish")
      expect(SiteBuildJob.jobs.first["at"]).to be_nil
      expect(flash[:alert]).to be_nil
      expect(flash[:notice]).to include("had passed")
    end

    it "refuses a date with no time" do
      post "/republish", params: { schedule: "later", date: "2026-08-25", time: "", time_zone: "UTC" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("Pick a date and a time")
    end

    it "refuses a date that is not valid" do
      post "/republish", params: { schedule: "later", date: "not-a-date", time: "06:30", time_zone: "UTC" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("not valid")
    end

    it "refuses a date past the horizon, which catches a year with a mistake" do
      post "/republish", params: { schedule: "later", date: "2062-08-25", time: "06:30", time_zone: "UTC" }

      expect(SiteBuildJob.jobs).to be_empty
      expect(flash[:alert]).to include("90 days")
    end

    it "reads the time in UTC when the browser sent no zone" do
      travel_to Time.utc(2026, 8, 24, 12, 0, 0) do
        post "/republish", params: { schedule: "later", date: "2026-08-24", time: "18:00" }
      end

      expect(SiteBuildJob).to have_enqueued_sidekiq_job("admin-republish").at(Time.utc(2026, 8, 24, 18, 0, 0))
    end
  end

  describe "without an owner session" do
    it "refuses to start a build" do
      post "/republish", params: { schedule: "now" }

      expect(response).to redirect_to("/signin")
      expect(SiteBuildJob.jobs).to be_empty
    end
  end
end
