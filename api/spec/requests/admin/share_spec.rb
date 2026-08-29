require "rails_helper"

RSpec.describe "Admin share", type: :request do
  let(:owner_email) { "owner@example.com" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("OWNER_EMAIL").and_return(owner_email)
    allow_any_instance_of(FontAwesome).to receive(:svg).and_return('<svg class="stub-icon"></svg>')

    # The credentials of each network live in Redis. Each example says which ones are connected.
    $redis.del(BlueskyCredentials::REDIS_KEY, MastodonCredentials::REDIS_KEY, ThreadsCredentials::REDIS_KEY)
    connect(bluesky: true, mastodon: false, threads: false)
  end

  after { $redis.del(BlueskyCredentials::REDIS_KEY, MastodonCredentials::REDIS_KEY, ThreadsCredentials::REDIS_KEY) }

  before { SharePostJob.jobs.clear }

  def connect(bluesky:, mastodon:, threads:)
    allow_any_instance_of(StandardSite).to receive(:connected?).and_return(bluesky)
    allow_any_instance_of(StandardSite).to receive(:handle).and_return(bluesky ? "me.bsky.social" : nil)
    allow_any_instance_of(Mastodon).to receive(:connected?).and_return(mastodon)
    allow_any_instance_of(Mastodon).to receive(:handle).and_return(mastodon ? "@me@instance.test" : nil)
    allow_any_instance_of(Threads).to receive(:connected?).and_return(threads)
    allow_any_instance_of(Threads).to receive(:username).and_return(threads ? "me" : nil)
  end

  describe "GET /share" do
    it "needs the owner session" do
      get "/share"

      expect(response).to redirect_to("/signin")
    end

    context "when one account is connected" do
      before { sign_in_as(email: owner_email) }

      it "renders the composer and does not cache it" do
        get "/share"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<wa-input type="url" name="article_url"))
        expect(response.body).to include("<wa-textarea")
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      # ⚠️ The link field is a plain input and there is no list of the entries. Thus this page makes
      # no request to Contentful when it renders.
      it "reads no articles" do
        expect_any_instance_of(Articles).not_to receive(:list)

        get "/share"

        expect(response).to have_http_status(:ok)
      end

      it "writes the character limit into the markup for the controller to read" do
        get "/share"

        expect(response.body).to include(%(data-share-limit-value="#{SharePresenter::BODY_LIMIT}"))
        expect(response.body).to include(%(data-share-warn-at-value="#{SharePresenter::WARN_AT}"))
      end

      # The server renders the first count, thus the line has its height before the JavaScript
      # runs and the page does not move.
      it "renders the first count line" do
        get "/share"

        expect(response.body).to include("0 / #{SharePresenter::BODY_LIMIT}")
      end

      it "names the account of a connected network and disables one that is not connected" do
        get "/share"

        expect(response.body).to include("Posts as @me.bsky.social.")
        expect(response.body).to include('<wa-checkbox name="networks[]" value="mastodon" disabled>')
        expect(response.body).to include("Not connected.")
      end

      # ⚠️ The house rule: every submit is a <wa-button> in a form_with, and never a native button.
      it "renders no native button" do
        get "/share"

        expect(response.body).not_to include("<button")
      end

      it "puts the item in the nav" do
        get "/share"

        expect(response.body).to include("Share a post")
      end
    end

    describe "POST /share" do
      before { sign_in_as(email: owner_email) }

      let(:url) { "https://example.test/2026/07/12/ironman-canada/" }


      it "adds one job with the link, the body, and the networks" do
        post "/share", params: { article_url: url, body: "A long day.", networks: [ "bluesky" ] }

        expect(response).to redirect_to(share_path)
        expect(flash[:notice]).to include("Queued a post to Bluesky.")
        expect(SharePostJob.jobs.size).to eq(1)
        rkey, link, body, networks = SharePostJob.jobs.first["args"]
        expect(link).to eq(url)
        expect(body).to eq("A long day.")
        expect(networks).to eq([ "bluesky" ])
        # ⚠️ The controller makes the record key, and the job writes with putRecord at that key.
        # Thus a Sidekiq retry replaces one post and does not add a second one.
        expect(rkey).to match(/\A[234567a-z]{13}\z/)
      end

      # The owner chose to be able to tick a network that no code sends to yet. The notice must
      # then say so, or a post that never arrives looks like a failure.
      it "names a network that it cannot post to yet" do
        connect(bluesky: true, mastodon: true, threads: false)

        post "/share", params: { article_url: url, body: "Hi.", networks: %w[bluesky mastodon] }

        expect(flash[:notice]).to include("Queued a post to Bluesky.")
        expect(flash[:notice]).to include("Mastodon isn't wired up yet.")
      end

      # ⚠️ The link field takes any URL, thus the owner can share a page on another site.
      it "takes a link that is not an article of this site" do
        post "/share", params: { article_url: "https://someone-else.test/a-post/", body: "Good.",
                                 networks: [ "bluesky" ] }

        expect(response).to redirect_to(share_path)
        expect(SharePostJob.jobs.first["args"][1]).to eq("https://someone-else.test/a-post/")
      end

      it "ignores a network key that this app does not know" do
        post "/share", params: { article_url: url, body: "Hi.", networks: %w[bluesky myspace] }

        expect(SharePostJob.jobs.first["args"].last).to eq([ "bluesky" ])
      end

      describe "scheduling" do
        # Any date in the future. ⚠️ It must not be a constant: a date that a person writes here
        # becomes the past, and the action then refuses it and the example fails one day.
        let(:on) { 10.days.from_now.strftime("%Y-%m-%d") }

        # ⚠️ A date and a time carry no zone. The browser sends its own IANA id, thus "09:00" has
        # one meaning. This is the difference from the Republish dialog, which takes minutes from
        # now for exactly this reason.
        it "reads the date and the time in the zone that the browser sent" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00",
                                   time_zone: "America/New_York" }

          expect(response).to redirect_to(share_path)
          expected = Time.use_zone("America/New_York") { Time.zone.parse("#{on} 09:00") }
          expect(SharePostJob.jobs.first["at"]).to be_within(1).of(expected.to_f)
        end

        it "names the moment in the notice, in that same zone" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00",
                                   time_zone: "America/New_York" }

          expected = Time.use_zone("America/New_York") do
            Time.zone.parse("#{on} 09:00").strftime("%B %-e at %-I:%M %p %Z")
          end
          expect(flash[:notice]).to eq("Scheduled a post to Bluesky for #{expected}.")
        end

        # ⚠️ With no JavaScript the hidden field is empty. TIME_ZONE is then the meaning, and the
        # form still works.
        it "falls back to the configured zone with no time zone field" do
          allow(TimeZoneResolver).to receive(:default).and_return("America/Denver")

          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00" }

          expected = Time.use_zone("America/Denver") { Time.zone.parse("#{on} 09:00") }
          expect(SharePostJob.jobs.first["at"]).to be_within(1).of(expected.to_f)
        end

        # That field comes from the browser, thus a value with a mistake must never raise.
        it "falls back for a time zone that Rails does not know" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00",
                                   time_zone: "Mars/Olympus_Mons" }

          expect(response).to redirect_to(share_path)
          expect(SharePostJob.jobs.size).to eq(1)
        end

        it "posts now when the switch is off, and schedules nothing" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "0", date: on, time: "09:00" }

          expect(flash[:notice]).to include("Queued a post to Bluesky.")
          expect(SharePostJob.jobs.first["at"]).to be_nil
        end

        it "refuses a moment in the past" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: "2020-01-01", time: "09:00" }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Pick a time in the future.")
          expect(SharePostJob.jobs).to be_empty
        end

        # ⚠️ There is no limit on how far ahead this can be, on purpose. A post about a race can
        # wait for the race.
        it "takes a moment years from now" do
          far = 3.years.from_now

          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: far.strftime("%Y-%m-%d"), time: "09:00" }

          expect(response).to redirect_to(share_path)
          expect(SharePostJob.jobs.size).to eq(1)
        end

        it "refuses a schedule with no date, and keeps the fields open" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [ "bluesky" ],
                                   schedule: "1", date: "", time: "09:00" }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Pick a date and a time to schedule it.")
          expect(response.body).to include(%(value="09:00"))
          expect(response.body).to include("<wa-switch name=\"schedule\" value=\"1\" checked")
          expect(SharePostJob.jobs).to be_empty
        end
      end

      # ⚠️ A refusal renders the page again and keeps the draft. A redirect would lose it.
      context "when the draft is not good" do
        it "refuses an empty body and keeps the picker" do
          post "/share", params: { article_url: url, body: "", networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Write something to post.")
          expect(response.body).to include(%(value="#{url}"))
          expect(SharePostJob.jobs).to be_empty
        end

        it "refuses a body past the limit and keeps it in the field" do
          long = "a" * (Bluesky::MAX_GRAPHEMES + 1)

          post "/share", params: { article_url: url, body: long, networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("301 characters")
          expect(response.body).to include(long)
          expect(SharePostJob.jobs).to be_empty
        end

        it "refuses a value that is not a URL" do
          post "/share", params: { article_url: "not a link", body: "Hi.", networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Paste a link to share.")
          expect(SharePostJob.jobs).to be_empty
        end

        it "refuses a draft with no network" do
          post "/share", params: { article_url: url, body: "Hi.", networks: [] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include("Pick at least one place to post it.")
          expect(SharePostJob.jobs).to be_empty
        end
      end
    end

    # ⚠️ The page is a draft screen, thus it renders with no account at all. Each row is then
    # disabled, and the owner can still look at the page and change it.
    context "when no account is connected" do
      before do
        connect(bluesky: false, mastodon: false, threads: false)
        sign_in_as(email: owner_email)
      end

      it "still renders the composer" do
        get "/share"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(name="article_url"))
      end

      it "disables each of the three rows" do
        get "/share"

        %w[bluesky mastodon threads].each do |key|
          expect(response.body).to include(%(<wa-checkbox name="networks[]" value="#{key}" disabled>))
        end
      end

      it "keeps the item in the nav" do
        get "/connected-apps"

        expect(response.body).to include("Share a post")
      end
    end
  end
end
