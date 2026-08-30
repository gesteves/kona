require "rails_helper"

RSpec.describe "Admin social media", type: :request do
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

  # One job for each network, thus each example clears all three.
  before { [ BlueskyPostJob, MastodonPostJob, ThreadsPostJob ].each { |job| job.jobs.clear } }

  def connect(bluesky:, mastodon:, threads:)
    allow_any_instance_of(StandardSite).to receive(:connected?).and_return(bluesky)
    allow_any_instance_of(StandardSite).to receive(:handle).and_return(bluesky ? "me.bsky.social" : nil)
    allow_any_instance_of(Mastodon).to receive(:connected?).and_return(mastodon)
    allow_any_instance_of(Mastodon).to receive(:handle).and_return(mastodon ? "@me@instance.test" : nil)
    allow_any_instance_of(Threads).to receive(:connected?).and_return(threads)
    allow_any_instance_of(Threads).to receive(:usable?).and_return(threads)
    allow_any_instance_of(Threads).to receive(:expired?).and_return(false)
    allow_any_instance_of(Threads).to receive(:username).and_return(threads ? "me" : nil)
  end

  # A Threads account whose token is dead: connected, and not usable.
  def expire_threads
    allow_any_instance_of(Threads).to receive(:connected?).and_return(true)
    allow_any_instance_of(Threads).to receive(:usable?).and_return(false)
    allow_any_instance_of(Threads).to receive(:expired?).and_return(true)
    allow_any_instance_of(Threads).to receive(:username).and_return("me")
  end

  describe "GET /social" do
    it "needs the owner session" do
      get "/social"

      expect(response).to redirect_to("/signin")
    end

    context "when one account is connected" do
      before { sign_in_as(email: owner_email) }

      it "renders the composer and does not cache it" do
        get "/social"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(<wa-input type="url" name="posts[][link]"))
        expect(response.body).to include("<wa-textarea")
        expect(response.headers["Cache-Control"]).to include("no-store")
      end

      # ⚠️ The link field is a plain input and there is no list of the entries. Thus this page makes
      # no request to Contentful when it renders.
      it "reads no articles" do
        expect_any_instance_of(Articles).not_to receive(:list)

        get "/social"

        expect(response).to have_http_status(:ok)
      end

      it "writes the character limit into the markup for the controller to read" do
        get "/social"

        expect(response.body).to include(%(data-social-post-limit-value="#{SocialPresenter::BODY_LIMIT}"))
        expect(response.body).to include(%(data-social-post-warn-at-value="#{SocialPresenter::WARN_AT}"))
      end

      # The server renders the first count, thus the line has its height before the JavaScript
      # runs and the page does not move.
      it "renders the first count line" do
        get "/social"

        expect(response.body).to include("0 / #{SocialPresenter::BODY_LIMIT}")
      end

      it "names the account of a connected network and disables one that is not connected" do
        get "/social"

        expect(response.body).to include(I18n.t("admin.social.account.named", account: "@me.bsky.social"))
        expect(response.body).to include('<wa-checkbox name="networks[]" value="mastodon" disabled>')
        expect(response.body).to include(I18n.t("admin.social.show.not_connected"))
      end

      it "names the account of each of the three networks" do
        connect(bluesky: true, mastodon: true, threads: true)

        get "/social"

        expect(response.body).to include(I18n.t("admin.social.account.named", account: "@me.bsky.social"))
        expect(response.body).to include(I18n.t("admin.social.account.named", account: "@me@instance.test"))
        expect(response.body).to include(I18n.t("admin.social.account.named", account: "@me"))
      end

      # The owner posts to each connected network nearly always, thus the page must not ask for
      # three clicks each time.
      it "ticks each connected row and not a disabled one" do
        connect(bluesky: true, mastodon: true, threads: false)

        get "/social"

        expect(response.body).to match(/value="bluesky"[^>]*\schecked>/)
        expect(response.body).to match(/value="mastodon"[^>]*\schecked>/)
        expect(response.body).not_to match(/value="threads"[^>]*\schecked>/)
      end

      # ⚠️ A dead Threads token is connected and cannot post. The row must say so, and not
      # "Not connected", which would send the owner to look for a card that is green.
      it "disables the Threads row when its token expired, and says why" do
        expire_threads

        get "/social"

        expect(response.body).to include('<wa-checkbox name="networks[]" value="threads" disabled>')
        expect(response.body).to include(I18n.t("admin.social.status.threads_expired"))
      end

      # ⚠️ Each state comes from Redis. An upstream failure must not go into the path of a page
      # load, thus this page makes no HTTP request at all.
      it "makes no HTTP request" do
        expect(HTTParty).not_to receive(:get)
        expect(HTTParty).not_to receive(:post)

        get "/social"

        expect(response).to have_http_status(:ok)
      end

      # ⚠️ The house rule: every submit is a <wa-button> in a form_with, and never a native button.
      it "renders no native button" do
        get "/social"

        expect(response.body).not_to include("<button")
      end

      it "puts the item in the nav" do
        get "/social"

        expect(response.body).to include(I18n.t("admin.pages.social"))
      end
    end

    describe "GET /social/preview" do
      before { sign_in_as(email: owner_email) }

      let(:card) do
        OpenGraph::Card.new(url: "https://example.test/a/", title: "A title",
                            description: "A summary.", image_url: "https://cdn.test/og.png",
                            document_uri: "at://did:plc:abc/site.standard.document/d1")
      end

      it "needs the owner session" do
        reset!

        get "/social/preview", params: { url: "https://example.test/a/" }

        expect(response).to redirect_to("/signin")
      end

      it "gives the card of the link" do
        allow_any_instance_of(OpenGraph).to receive(:fetch).and_return(card)

        get "/social/preview", params: { url: "https://example.test/a/" }

        body = response.parsed_body
        expect(body["title"]).to eq("A title")
        expect(body["description"]).to eq("A summary.")
        expect(body["host"]).to eq("example.test")
      end

      # ⚠️ This is the useful part: the owner cannot know which of the two cards Bluesky will
      # render until after the post without it.
      it "says when the page publishes standard.site records" do
        allow_any_instance_of(OpenGraph).to receive(:fetch).and_return(card)

        get "/social/preview", params: { url: "https://example.test/a/" }

        expect(response.parsed_body["standard_site"]).to be(true)
      end

      it "says when it is an ordinary link card" do
        allow_any_instance_of(OpenGraph).to receive(:fetch)
          .and_return(OpenGraph::Card.new(url: "https://other.test/", title: "T", description: nil,
                                          image_url: nil))

        get "/social/preview", params: { url: "https://other.test/" }

        expect(response.parsed_body["standard_site"]).to be(false)
      end

      # ⚠️ The og:image itself is never in the answer. The CSP of the admin has `img-src :self`,
      # thus the browser must ask this app for the picture.
      it "gives the path of our own proxy and not the og:image" do
        allow_any_instance_of(OpenGraph).to receive(:fetch).and_return(card)

        get "/social/preview", params: { url: "https://example.test/a/" }

        expect(response.parsed_body["image_path"]).to start_with("/social/preview/image")
        expect(response.body).not_to include("cdn.test")
      end

      it "gives no image path for a page with no picture" do
        allow_any_instance_of(OpenGraph).to receive(:fetch)
          .and_return(OpenGraph::Card.new(url: "https://other.test/", title: "T", description: nil,
                                          image_url: nil))

        get "/social/preview", params: { url: "https://other.test/" }

        expect(response.parsed_body["image_path"]).to be_nil
      end

      it "refuses a value that is not a link, and reads nothing" do
        expect_any_instance_of(OpenGraph).not_to receive(:fetch)

        get "/social/preview", params: { url: "not a link" }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "GET /social/preview/image" do
      before { sign_in_as(email: owner_email) }

      let(:card) do
        OpenGraph::Card.new(url: "https://example.test/a/", title: "T", description: nil,
                            image_url: "https://cdn.test/og.png")
      end

      it "needs the owner session" do
        reset!

        get "/social/preview/image", params: { url: "https://example.test/a/" }

        expect(response).to redirect_to("/signin")
      end

      # ⚠️ The parameter is the page, and not the picture. Thus a caller cannot name any URL for
      # this app to get: the picture is always the one that the og: tags of that page name.
      # `Bluesky#card_image` gives the same bytes that go up as the blob.
      it "sends the picture that the og: tags of the page name" do
        allow_any_instance_of(OpenGraph).to receive(:fetch).and_return(card)
        allow_any_instance_of(Bluesky).to receive(:card_image)
          .with("https://cdn.test/og.png")
          .and_return({ body: "bytes", content_type: "image/png" })

        get "/social/preview/image", params: { url: "https://example.test/a/" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("image/png")
        expect(response.body).to eq("bytes")
      end

      it "answers 404 for a page with no picture" do
        allow_any_instance_of(OpenGraph).to receive(:fetch)
          .and_return(OpenGraph::Card.new(url: "https://other.test/", title: nil, description: nil,
                                          image_url: nil))

        get "/social/preview/image", params: { url: "https://other.test/" }

        expect(response).to have_http_status(:not_found)
      end

      it "answers 404 when the picture cannot be read" do
        allow_any_instance_of(OpenGraph).to receive(:fetch).and_return(card)
        allow_any_instance_of(Bluesky).to receive(:card_image).and_return(nil)

        get "/social/preview/image", params: { url: "https://example.test/a/" }

        expect(response).to have_http_status(:not_found)
      end

      it "refuses a value that is not a link" do
        get "/social/preview/image", params: { url: "javascript:alert(1)" }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "POST /social" do
      before { sign_in_as(email: owner_email) }

      let(:url) { "https://example.test/2026/07/12/ironman-canada/" }


      it "adds the job of the network, with the link and the body" do
        post "/social", params: { posts: [ { text: "A long day.", link: url } ], networks: [ "bluesky" ] }

        expect(response).to redirect_to(social_path)
        expect(flash[:notice]).to eq(I18n.t("admin.social.flash.sent", networks: "Bluesky"))
        expect(BlueskyPostJob.jobs.size).to eq(1)
        payload = BlueskyPostJob.jobs.first["args"].first
        expect(payload.length).to eq(1)
        expect(payload.first["link"]).to eq(url)
        expect(payload.first["text"]).to eq("A long day.")
        # ⚠️ The controller makes the key of each post, and each job writes at that key. Thus a
        # Sidekiq retry replaces one post and does not add a second one.
        expect(payload.first["key"]).to match(/\A[234567a-z]{13}\z/)
      end

      # ⚠️ The link is optional. A post with no link is words alone, and it makes no card.
      it "takes a post with no link" do
        post "/social", params: { posts: [ { text: "No link here." } ], networks: [ "bluesky" ] }

        expect(response).to redirect_to(social_path)
        expect(BlueskyPostJob.jobs.first["args"].first.first["link"]).to eq("")
      end

      describe "a thread" do
        # ⚠️ The form sends `posts[][text]` and `posts[][link]`, and Rails starts a new hash when a
        # key repeats. Thus each pair must stay together and in order.
        it "adds one job for the thread, with each post in order and a key of its own" do
          post "/social", params: {
            posts: [ { text: "One", link: "https://example.test/a/" },
                     { text: "Two", link: "" },
                     { text: "Three", link: "https://example.test/b/" } ],
            networks: [ "bluesky" ]
          }

          expect(response).to redirect_to(social_path)
          expect(BlueskyPostJob.jobs.size).to eq(1)
          payload = BlueskyPostJob.jobs.first["args"].first
          expect(payload.map { |p| p["text"] }).to eq(%w[One Two Three])
          expect(payload.map { |p| p["link"] })
            .to eq([ "https://example.test/a/", "", "https://example.test/b/" ])
          expect(payload.map { |p| p["key"] }.uniq.length).to eq(3)
        end

        it "names each network in the notice" do
          connect(bluesky: true, mastodon: true, threads: false)

          post "/social", params: { posts: [ { text: "One" }, { text: "Two" } ],
                                    networks: %w[bluesky mastodon] }

          expect(flash[:notice]).to eq(I18n.t("admin.social.flash.sent", networks: "Bluesky and Mastodon"))
        end

        # ⚠️ Only the FIRST post of each network is scheduled. That job adds the next one when it
        # succeeds, thus the rest of the thread needs no time of its own.
        it "schedules the first job of each network only" do
          on = 10.days.from_now.strftime("%Y-%m-%d")

          post "/social", params: { posts: [ { text: "One" }, { text: "Two" } ],
                                    networks: [ "bluesky" ], schedule: "1", date: on,
                                    time: "09:00", time_zone: "America/Denver" }

          expect(BlueskyPostJob.jobs.size).to eq(1)
          expect(BlueskyPostJob.jobs.first["at"]).to be_present
          expect(flash[:notice]).to include(t_before("admin.social.flash.scheduled", :at, networks: "Bluesky"))
        end

        # An empty block that the owner added and left alone must not refuse the whole draft.
        it "drops a block with nothing in it" do
          post "/social", params: { posts: [ { text: "One" }, { text: "", link: "" } ],
                                    networks: [ "bluesky" ] }

          expect(response).to redirect_to(social_path)
          expect(BlueskyPostJob.jobs.first["args"].first.length).to eq(1)
        end

        # ⚠️ A message names the post: a thread has more than one, and a plain message does not say
        # which one is wrong.
        it "names the post that is too long" do
          post "/social", params: { posts: [ { text: "One" }, { text: "a" * 301 } ],
                                    networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.too_long.numbered", index: 2, count: 301, limit: Bluesky::MAX_GRAPHEMES))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "names the post with a link that is not a link" do
          post "/social", params: { posts: [ { text: "One" }, { text: "Two", link: "nope" } ],
                                    networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.bad_link.numbered", index: 2))
        end

        it "refuses a post of the thread that has a link and no words" do
          post "/social", params: {
            posts: [ { text: "One" }, { text: "", link: "https://example.test/a/" } ],
            networks: [ "bluesky" ]
          }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.text_missing.numbered", index: 2))
        end

        it "refuses a thread past the limit" do
          post "/social", params: {
            posts: Array.new(SocialPresenter::MAX_POSTS + 1) { |i| { text: "Post #{i}" } },
            networks: [ "bluesky" ]
          }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.too_many_posts", count: SocialPresenter::MAX_POSTS))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        # ⚠️ A refusal renders again and keeps every post. A redirect would lose what the owner
        # wrote, and a thread is more of it.
        it "puts every post back after a refusal, in order" do
          post "/social", params: { posts: [ { text: "First words" }, { text: "a" * 301 } ],
                                    networks: [ "bluesky" ] }

          expect(response.body).to include("First words")
          expect(response.body).to include("a" * 301)
        end
      end

      # ⚠️ One job for each network, thus a failure at one service retries that service alone.
      it "adds one job for each network, and gives all three the same key" do
        connect(bluesky: true, mastodon: true, threads: true)

        post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: %w[bluesky mastodon threads] }

        expect(flash[:notice]).to eq(I18n.t("admin.social.flash.sent", networks: "Bluesky, Mastodon, and Threads"))
        # ⚠️ It compares the KEY of each post and not the whole payload. The three networks get a
        # different text when the draft names a person, and they must still share one key.
        keys = [ BlueskyPostJob, MastodonPostJob, ThreadsPostJob ].map do |job|
          expect(job.jobs.size).to eq(1)
          job.jobs.first["args"].first.map { |post| post["key"] }
        end
        expect(keys.uniq.size).to eq(1)
        expect(keys.first.compact.size).to eq(1)
      end

      # A request that a person writes by hand, and the shape that an empty `posts[]` sends.
      it "refuses a body whose posts are not blocks, and does not give a 500" do
        post "/social", params: { posts: "", mentions: "", networks: [ "bluesky" ] }

        expect(response).to have_http_status(:unprocessable_content)
        expect(flash[:alert]).to eq(I18n.t("admin.social.errors.empty"))
        expect(BlueskyPostJob.jobs).to be_empty
      end

      it "adds no job for a network that the owner did not tick" do
        connect(bluesky: true, mastodon: true, threads: true)

        post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "mastodon" ] }

        expect(MastodonPostJob.jobs.size).to eq(1)
        expect(BlueskyPostJob.jobs).to be_empty
        expect(ThreadsPostJob.jobs).to be_empty
      end

      # ⚠️ A row with no account renders `disabled`, thus a browser cannot tick it. A request that
      # a person writes by hand can, and the job would then retry "not connected" for 24 hours.
      it "refuses a network that has no account" do
        connect(bluesky: true, mastodon: false, threads: false)

        post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "mastodon" ] }

        expect(response).to have_http_status(:unprocessable_content)
        expect(MastodonPostJob.jobs).to be_empty
      end

      # ⚠️ The link field takes any URL, thus the owner can share a page on another site.
      it "takes a link that is not an article of this site" do
        post "/social", params: { posts: [ { text: "Good.", link: "https://someone-else.test/a-post/" } ],
                                 networks: [ "bluesky" ] }

        expect(response).to redirect_to(social_path)
        expect(BlueskyPostJob.jobs.first["args"].first.first["link"])
          .to eq("https://someone-else.test/a-post/")
      end

      it "ignores a network key that this app does not know" do
        post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: %w[bluesky myspace] }

        expect(BlueskyPostJob.jobs.size).to eq(1)
        expect(flash[:notice]).to eq(I18n.t("admin.social.flash.sent", networks: "Bluesky"))
      end

      # ⚠️ A dead Threads token is connected and cannot post. Without this check the job would
      # raise at Meta and retry for 24 hours.
      it "refuses the Threads row when its token expired" do
        expire_threads

        post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "threads" ] }

        expect(response).to have_http_status(:unprocessable_content)
        expect(ThreadsPostJob.jobs).to be_empty
      end

      # ⚠️ The body is stripped one time, here. Without that a newline at its end went to Bluesky
      # as it was and to Mastodon with the newline removed.
      it "strips the body before it counts it and before it adds the job" do
        post "/social", params: { posts: [ { text: "  A long day.\n\n", link: url } ], networks: [ "bluesky" ] }

        expect(response).to redirect_to(social_path)
        expect(BlueskyPostJob.jobs.first["args"].first.first["text"]).to eq("A long day.")
      end

      it "refuses a body that is only white space" do
        post "/social", params: { posts: [ { text: " \n ", link: url } ], networks: [ "bluesky" ] }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t("admin.social.errors.text_missing.single"))
      end

      # ⚠️ A submit that fails keeps the ticks of the owner, and an empty choice is a choice. The
      # default ticks apply to the first load only.
      it "keeps the rows unticked after a refusal when the owner unticked them" do
        connect(bluesky: true, mastodon: true, threads: false)

        post "/social", params: { posts: [ { text: "", link: url } ], networks: [] }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to match(/value="bluesky"[^>]*\schecked>/)
        expect(response.body).not_to match(/value="mastodon"[^>]*\schecked>/)
      end

      describe "scheduling" do
        # Any date in the future. ⚠️ It must not be a constant: a date that a person writes here
        # becomes the past, and the action then refuses it and the example fails one day.
        let(:on) { 10.days.from_now.strftime("%Y-%m-%d") }

        # ⚠️ A date and a time carry no zone. The browser sends its own IANA id, thus "09:00" has
        # one meaning. This is the difference from the Republish dialog, which takes minutes from
        # now for exactly this reason.
        it "reads the date and the time in the zone that the browser sent" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00",
                                   time_zone: "America/New_York" }

          expect(response).to redirect_to(social_path)
          expected = Time.use_zone("America/New_York") { Time.zone.parse("#{on} 09:00") }
          expect(BlueskyPostJob.jobs.first["at"]).to be_within(1).of(expected.to_f)
        end

        it "names the moment in the notice, in that same zone" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00",
                                   time_zone: "America/New_York" }

          expected = Time.use_zone("America/New_York") do
            Time.zone.parse("#{on} 09:00").strftime("%B %-e at %-I:%M %p %Z")
          end
          expect(flash[:notice]).to eq(I18n.t("admin.social.flash.scheduled", networks: "Bluesky", at: expected))
        end

        # ⚠️ With no JavaScript the hidden field is empty. TIME_ZONE is then the meaning, and the
        # form still works.
        it "falls back to the configured zone with no time zone field" do
          allow(TimeZoneResolver).to receive(:default).and_return("America/Denver")

          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00" }

          expected = Time.use_zone("America/Denver") { Time.zone.parse("#{on} 09:00") }
          expect(BlueskyPostJob.jobs.first["at"]).to be_within(1).of(expected.to_f)
        end

        # That field comes from the browser, thus a value with a mistake must never raise.
        it "falls back for a time zone that Rails does not know" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "09:00",
                                   time_zone: "Mars/Olympus_Mons" }

          expect(response).to redirect_to(social_path)
          expect(BlueskyPostJob.jobs.size).to eq(1)
        end

        it "posts now when the switch is off, and schedules nothing" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "0", date: on, time: "09:00" }

          expect(flash[:notice]).to eq(I18n.t("admin.social.flash.sent", networks: "Bluesky"))
          expect(BlueskyPostJob.jobs.first["at"]).to be_nil
        end

        # ⚠️ A moment that has PASSED is not an error: it is not a schedule, thus the post goes out
        # at once. The label of the submit button says "Post now" for that same draft, and a
        # refusal here would make that button a liar.
        it "posts at once for a moment that has passed" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: "2020-01-01", time: "09:00" }

          expect(response).to redirect_to(social_path)
          expect(flash[:notice]).to eq(I18n.t("admin.social.flash.sent", networks: "Bluesky"))
          expect(BlueskyPostJob.jobs.size).to eq(1)
          expect(BlueskyPostJob.jobs.first["at"]).to be_nil
        end

        # ⚠️ There is no limit on how far ahead this can be, on purpose. A post about a race can
        # wait for the race.
        it "takes a moment years from now" do
          far = 3.years.from_now

          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: far.strftime("%Y-%m-%d"), time: "09:00" }

          expect(response).to redirect_to(social_path)
          expect(BlueskyPostJob.jobs.size).to eq(1)
        end

        # ⚠️ `Time.zone.parse("garbage 09:00")` gives today at 09:00. Without the check of the
        # shape, a value with a mistake would schedule a post for today.
        it "refuses a date that is not a date" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: "garbage", time: "09:00" }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.no_moment"))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "refuses a time that is not a time" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: on, time: "9 in the morning" }

          expect(response).to have_http_status(:unprocessable_content)
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "refuses a schedule with no date, and keeps the fields open" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [ "bluesky" ],
                                   schedule: "1", date: "", time: "09:00" }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.no_moment"))
          expect(response.body).to include(%(value="09:00"))
          expect(response.body).to include("<wa-switch name=\"schedule\" value=\"1\" checked")
          expect(BlueskyPostJob.jobs).to be_empty
        end
      end

      # ⚠️ A refusal renders the page again and keeps the draft. A redirect would lose it.
      context "when the draft is not good" do
        it "refuses an empty body and keeps the picker" do
          post "/social", params: { posts: [ { text: "", link: url } ], networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.text_missing.single"))
          expect(response.body).to include(%(value="#{url}"))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "refuses a body past the limit and keeps it in the field" do
          long = "a" * (Bluesky::MAX_GRAPHEMES + 1)

          post "/social", params: { posts: [ { text: long, link: url } ], networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.too_long.single", count: 301, limit: Bluesky::MAX_GRAPHEMES))
          expect(response.body).to include(long)
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "refuses a value that is not a URL" do
          post "/social", params: { posts: [ { text: "Hi.", link: "not a link" } ], networks: [ "bluesky" ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.bad_link.single"))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "refuses a draft with no network" do
          post "/social", params: { posts: [ { text: "Hi.", link: url } ], networks: [] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t("admin.social.errors.no_network"))
          expect(BlueskyPostJob.jobs).to be_empty
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
        get "/social"

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(name="posts[][text]"))
      end

      it "disables each of the three rows" do
        get "/social"

        %w[bluesky mastodon threads].each do |key|
          expect(response.body).to include(%(<wa-checkbox name="networks[]" value="#{key}" disabled>))
        end
      end

      it "keeps the item in the nav" do
        get "/connected-apps"

        expect(response.body).to include(I18n.t("admin.pages.social"))
      end
    end

    # The mention map of a draft. ⚠️ It is part of the draft and nothing stores it: the owner says
    # what one person is called at each network, and the action writes those words into the text of
    # each network before it adds the jobs.
    describe "POST /social with mentions" do
      before do
        sign_in_as(email: owner_email)
        connect(bluesky: true, mastodon: true, threads: true)
        # The handle check must not reach the network in an example that is not about it.
        allow_any_instance_of(Bluesky).to receive(:handle_missing?).and_return(false)
      end

      def text_of(job) = job.jobs.first["args"].first.first["text"]

      def post_draft(text:, mentions: [], networks: %w[bluesky mastodon threads])
        post "/social", params: { posts: [ { text: text, link: "" } ],
                                  mentions: mentions, networks: networks }
      end

      it "gives each network its own text from one body" do
        post_draft(text: "Great ride with @tony.",
                   mentions: [ { token: "@tony", bluesky: "tony.bsky.social",
                                 mastodon: "Anthony Edwards", threads: "@tony" } ])

        expect(text_of(BlueskyPostJob)).to eq("Great ride with @tony.bsky.social.")
        expect(text_of(MastodonPostJob)).to eq("Great ride with Anthony Edwards.")
        expect(text_of(ThreadsPostJob)).to eq("Great ride with @tony.")
      end

      # ⚠️ The case of a person with no account at that network. It is a correct answer.
      it "posts plain words with no @ where the owner gave a name" do
        post_draft(text: "Great ride with @tony.",
                   mentions: [ { token: "@tony", bluesky: "", mastodon: "Anthony Edwards",
                                 threads: "" } ])

        expect(text_of(MastodonPostJob)).to eq("Great ride with Anthony Edwards.")
      end

      it "keeps the words of the token, with no @, for a field that is empty" do
        post_draft(text: "Great ride with @Tony.",
                   mentions: [ { token: "@Tony", bluesky: "", mastodon: "", threads: "" } ])

        [ BlueskyPostJob, MastodonPostJob, ThreadsPostJob ].each do |job|
          expect(text_of(job)).to eq("Great ride with Tony.")
        end
      end

      # ⚠️ The server finds each token itself and reads the map as a lookup only. Thus a token that
      # the browser sent no row for still loses its "@", and it can never tag a stranger.
      it "removes the @ of a token that the form sent no row for" do
        post_draft(text: "Great ride with @tony.", mentions: [])

        expect(text_of(ThreadsPostJob)).to eq("Great ride with tony.")
      end

      it "reads a handle that the owner wrote with an @" do
        post_draft(text: "cc @tony", networks: [ "bluesky" ],
                   mentions: [ { token: "@tony", bluesky: "@tony.bsky.social", mastodon: "",
                                 threads: "" } ])

        expect(text_of(BlueskyPostJob)).to eq("cc @tony.bsky.social")
      end

      it "leaves a draft with no mention alone" do
        post_draft(text: "A long day.")

        expect(text_of(BlueskyPostJob)).to eq("A long day.")
      end

      describe "the character count" do
        # 292 words, and the handle adds 13 more. ⚠️ The raw body fits and the Bluesky text does not.
        let(:body) { "#{'a' * 286} @tony" }

        it "counts the text that Bluesky will get, and says so" do
          post_draft(text: body, networks: [ "bluesky" ],
                     mentions: [ { token: "@tony", bluesky: "tony.bsky.social", mastodon: "",
                                   threads: "" } ])

          expect(response).to have_http_status(:unprocessable_content)
          expect(flash[:alert]).to include(t_before("admin.social.errors.too_long_handles.single", :count, limit: Bluesky::MAX_GRAPHEMES))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        it "takes the same body when the handle is short enough" do
          post_draft(text: body, networks: [ "bluesky" ],
                     mentions: [ { token: "@tony", bluesky: "", mastodon: "", threads: "" } ])

          expect(response).to redirect_to(social_path)
        end
      end

      # ⚠️ A handle of another network in a field is otherwise mangled with no message.
      describe "a handle in the field of the wrong network" do
        it "refuses it, and names the field and the token" do
          post_draft(text: "cc @tony", networks: [ "bluesky" ],
                     mentions: [ { token: "@tony", bluesky: "tony@hachyderm.io", mastodon: "",
                                   threads: "" } ])

          expect(response).to have_http_status(:unprocessable_content)
          expect(flash[:alert]).to eq(I18n.t("admin.social.errors.mistaken_network", network: I18n.t("admin.networks.bluesky"),
                                                            token: "@tony",
                                                            other: I18n.t("admin.networks.mastodon")))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        # ⚠️ The check reads the ticked networks only.
        it "says nothing about a field of a network that the draft does not post to" do
          post_draft(text: "cc @tony", networks: [ "mastodon" ],
                     mentions: [ { token: "@tony", bluesky: "tony@hachyderm.io",
                                   mastodon: "tony@hachyderm.io", threads: "" } ])

          expect(response).to redirect_to(social_path)
        end

        # ⚠️ The case that DIAGNOSTIC_SHAPES protects: a name is not a mistake in any field.
        it "takes a plain name in every field" do
          post_draft(text: "cc @tony",
                     mentions: [ { token: "@tony", bluesky: "Tony", mastodon: "Tony",
                                   threads: "Tony" } ])

          expect(response).to redirect_to(social_path)
        end
      end

      describe "the Bluesky handle check" do
        let(:draft) do
          { token: "@tony", bluesky: "nobody.bsky.social", mastodon: "", threads: "" }
        end

        it "refuses a handle that the PDS does not know, and names it" do
          allow_any_instance_of(Bluesky).to receive(:handle_missing?).and_return(true)

          post_draft(text: "cc @tony", mentions: [ draft ])

          expect(response).to have_http_status(:unprocessable_content)
          expect(flash[:alert]).to include(I18n.t("admin.social.errors.bad_handle", handle: "nobody.bsky.social"))
          expect(BlueskyPostJob.jobs).to be_empty
        end

        # ⚠️ Fail open. An outage of the PDS must never stop a post to Mastodon and Threads.
        it "posts when the PDS does not answer" do
          allow_any_instance_of(Bluesky).to receive(:handle_missing?).and_return(false)

          post_draft(text: "cc @tony", mentions: [ draft ])

          expect(response).to redirect_to(social_path)
          expect(MastodonPostJob.jobs.size).to eq(1)
        end

        it "asks nothing when the owner does not post to Bluesky" do
          expect_any_instance_of(Bluesky).not_to receive(:handle_missing?)

          post_draft(text: "cc @tony", networks: %w[mastodon threads], mentions: [ draft ])

          expect(response).to redirect_to(social_path)
        end

        # Plain words are not a handle, thus there is nothing to ask about.
        it "asks nothing about a name" do
          expect_any_instance_of(Bluesky).not_to receive(:handle_missing?)

          post_draft(text: "cc @tony", networks: [ "bluesky" ],
                     mentions: [ { token: "@tony", bluesky: "Anthony Edwards", mastodon: "",
                                   threads: "" } ])

          expect(response).to redirect_to(social_path)
        end
      end

      # ⚠️ A refusal renders the page again, thus the owner must not lose the map that they filled.
      it "puts each row back after a refusal" do
        post "/social", params: {
          posts: [ { text: "cc @tony", link: "" } ],
          mentions: [ { token: "@tony", bluesky: "tony.bsky.social", mastodon: "Anthony Edwards",
                        threads: "" } ],
          networks: []
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("tony.bsky.social")
        expect(response.body).to include("Anthony Edwards")
      end
    end

    # The preview dialog. ⚠️ It reads the same fields as POST /social and it calls the same private
    # methods, thus it cannot show a text that the post does not send.
    describe "POST /social/preview/text" do
      before do
        sign_in_as(email: owner_email)
        connect(bluesky: true, mastodon: true, threads: true)
      end

      let(:url) { "https://example.test/2026/07/12/ironman-canada/" }

      def preview(posts:, mentions: [])
        post "/social/preview/text", params: { posts: posts, mentions: mentions }
        JSON.parse(response.body)
      end

      def rows(body, index = 0) = body["posts"][index]["networks"].index_by { |row| row["key"] }

      it "gives each network its own text from one body" do
        body = preview(posts: [ { text: "Great ride with @tony.", link: "" } ],
                       mentions: [ { token: "@tony", bluesky: "tony.bsky.social",
                                     mastodon: "Anthony Edwards", threads: "@tony" } ])

        expect(rows(body)["bluesky"]["text"]).to eq("Great ride with @tony.bsky.social.")
        expect(rows(body)["mastodon"]["text"]).to eq("Great ride with Anthony Edwards.")
        expect(rows(body)["threads"]["text"]).to eq("Great ride with @tony.")
      end

      # ⚠️ Mastodon joins the link into the TEXT, and the other two keep it out. This is the second
      # thing that makes the three different, and the owner cannot see it before this dialog.
      describe "the link" do
        let(:body) { preview(posts: [ { text: "A long day.", link: url } ]) }

        it "is in the Mastodon text and in no other one" do
          expect(rows(body)["mastodon"]["text"]).to eq("A long day.\n\n#{url}")
          expect(rows(body)["bluesky"]["text"]).to eq("A long day.")
          expect(rows(body)["threads"]["text"]).to eq("A long day.")
        end

        it "says where it went, for the two that keep it out of the text" do
          expect(rows(body)["bluesky"]["note"]).to eq(I18n.t("admin.social.preview.card"))
          expect(rows(body)["threads"]["note"]).to eq(I18n.t("admin.social.preview.attachment"))
          expect(rows(body)["mastodon"]["note"]).to be_nil
        end

        it "says nothing about a post with no link" do
          plain = preview(posts: [ { text: "A long day.", link: "" } ])

          expect(rows(plain).values.map { |row| row["note"] }).to all(be_nil)
        end
      end

      # ⚠️ The composition is Mastodon.compose, which Mastodon#post! calls. Without one method the
      # preview would show a text that the post does not send.
      it "composes the Mastodon text the way that the service does" do
        body = preview(posts: [ { text: "A long day.", link: url } ])

        expect(rows(body)["mastodon"]["text"])
          .to eq(Mastodon.compose(text: "A long day.", url: url))
      end

      describe "the counts" do
        it "counts graphemes for Bluesky and characters for the other two" do
          body = preview(posts: [ { text: "Ride 🚴‍♂️", link: "" } ])

          # The emoji is one grapheme at Bluesky and more than one UTF-16 unit here.
          expect(rows(body)["bluesky"]["length"]).to eq(6)
          expect(rows(body)["threads"]["length"]).to eq("Ride 🚴‍♂️".length)
        end

        # ⚠️ Mastodon counts a URL as URL_WEIGHT, whatever its true length.
        it "counts a Mastodon link at its weight and not its length" do
          long = "https://example.test/#{'a' * 200}"
          body = preview(posts: [ { text: "Hi", link: long } ])

          expect(rows(body)["mastodon"]["length"]).to eq(2 + 2 + Mastodon::URL_WEIGHT)
        end

        it "gives the limit of each network" do
          body = preview(posts: [ { text: "Hi", link: "" } ])

          expect(rows(body)["bluesky"]["limit"]).to eq(Bluesky::MAX_GRAPHEMES)
          expect(rows(body)["mastodon"]["limit"]).to eq(Mastodon::DEFAULT_MAX_CHARACTERS)
          expect(rows(body)["threads"]["limit"]).to eq(Threads::MAX_CHARACTERS)
        end

        # ⚠️ This is the check that stops the dialog and the action from drifting: a draft that the
        # action refuses must be `over` in the preview, and one that it takes must not be.
        it "marks over exactly when the action refuses the draft" do
          draft = { text: "#{'a' * 286} @tony", link: "" }
          mentions = [ { token: "@tony", bluesky: "tony.bsky.social", mastodon: "", threads: "" } ]

          expect(rows(preview(posts: [ draft ], mentions: mentions))["bluesky"]["over"]).to be true

          post "/social", params: { posts: [ draft ], mentions: mentions, networks: [ "bluesky" ] }
          expect(response).to have_http_status(:unprocessable_content)
        end

        it "does not mark over a draft that the action takes" do
          draft = { text: "a" * 290, link: "" }

          expect(rows(preview(posts: [ draft ]))["bluesky"]["over"]).to be false

          post "/social", params: { posts: [ draft ], networks: [ "bluesky" ] }
          expect(response).to redirect_to(social_path)
        end
      end

      it "gives the connected networks only" do
        connect(bluesky: true, mastodon: false, threads: false)

        body = preview(posts: [ { text: "Hi", link: "" } ])

        expect(rows(body).keys).to eq([ "bluesky" ])
      end

      describe "a thread" do
        let(:body) do
          preview(posts: [ { text: "One", link: "" }, { text: "Two", link: "" } ])
        end

        it "gives one group for each post, in order" do
          expect(body["posts"].length).to eq(2)
          expect(rows(body, 0)["bluesky"]["text"]).to eq("One")
          expect(rows(body, 1)["bluesky"]["text"]).to eq("Two")
        end

        it "names each post" do
          expect(body["posts"].map { |post| post["label"] })
            .to eq([ I18n.t("admin.social.preview.post", index: 1),
                     I18n.t("admin.social.preview.post", index: 2) ])
        end

        # A draft of one post needs no number.
        it "names nothing when there is one post" do
          one = preview(posts: [ { text: "One", link: "" } ])

          expect(one["posts"].first["label"]).to be_nil
        end
      end

      it "gives no post for an empty draft" do
        expect(preview(posts: [])["posts"]).to eq([])
      end

      # ⚠️ It is a preview and not a submit: it must add no job and it must write nothing.
      it "adds no job" do
        preview(posts: [ { text: "Hi", link: url } ])

        expect(BlueskyPostJob.jobs).to be_empty
        expect(MastodonPostJob.jobs).to be_empty
        expect(ThreadsPostJob.jobs).to be_empty
      end

      it "writes nothing to Redis" do
        allow($redis).to receive(:set).and_raise("the preview must not write")
        allow($redis).to receive(:hset).and_raise("the preview must not write")

        expect { preview(posts: [ { text: "Hi", link: url } ]) }.not_to raise_error
      end

      it "asks Bluesky about no handle" do
        # The handle check belongs to the submit. A preview must call no other service.
        expect_any_instance_of(Bluesky).not_to receive(:handle_missing?)

        preview(posts: [ { text: "cc @tony", link: "" } ],
                mentions: [ { token: "@tony", bluesky: "nobody.bsky.social", mastodon: "",
                              threads: "" } ])
      end

      it "needs the owner session" do
        reset!

        post "/social/preview/text", params: { posts: [ { text: "Hi", link: "" } ] }

        expect(response).to redirect_to("/signin")
      end

      # ⚠️ The admin does not skip the forgery protection, thus this POST needs the CSRF token, and
      # `social_controller.js` sends it in a header. The test environment turns that protection OFF,
      # thus each example above passes with no token and none of them can prove this. This one turns
      # it on: without the header the action would give a 422 in production alone, and the dialog
      # would say only that the preview could not be loaded.
      context "when the forgery protection is on" do
        around do |example|
          was = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          example.run
          ActionController::Base.allow_forgery_protection = was
        end

        it "takes the token of the page in a header" do
          get "/social"
          token = Nokogiri::HTML(response.body).at("meta[name=csrf-token]")&.[]("content")
          expect(token).to be_present, "the page renders no CSRF token for the browser to send"

          post "/social/preview/text", params: { posts: [ { text: "Hi", link: "" } ] },
                                       headers: { "X-CSRF-Token" => token }

          expect(response).to have_http_status(:ok)
        end

        it "refuses the same request with no token" do
          post "/social/preview/text", params: { posts: [ { text: "Hi", link: "" } ] }

          expect(response).not_to have_http_status(:ok)
        end
      end

      it "does not store the response" do
        preview(posts: [ { text: "Hi", link: "" } ])

        expect(response.headers["Cache-Control"]).to include("no-store")
      end
    end
  end
end
