module Admin
  # The Social media page: the owner pastes a link, drafts one body, and the action adds one post
  # job for each network that they ticked.
  #
  # ⚠️ There is one job for each network, and not one job for all of them. Thus a failure at one
  # service retries that service alone, and a network that already posted is never sent again.
  #
  # `SocialDraft` reads the form and makes the text of each network, `SocialDraftValidator` refuses
  # a draft that cannot go out, and `SocialPreview` makes the JSON of the preview. ⚠️ Each action
  # gives them one draft, thus the check, the preview, and the jobs all read the same text.
  class SocialController < BaseController
    # How much longer than its schedule a photo stays in Redis: the 24-hour retry window of the
    # job and an hour more. ⚠️ Without this a post that waits more than a day would find its
    # photos gone, and the job would then fail it.
    PHOTO_KEEP_MARGIN = 25.hours

    # GET /social
    #
    # ⚠️ The page renders with no account connected, and each row is then disabled. It is a draft
    # screen, thus it must be available to look at and to change before an account exists.
    def show
      @social = presenter
    end

    # POST /social
    def create
      error = SocialDraftValidator.new(draft).error

      # ⚠️ It renders again and does not redirect. A redirect would lose the words that the owner
      # wrote, and the draft is the expensive part of this page.
      if error
        @social = presenter(posts: draft.posts, mentions: draft.mention_rows,
                            selected: draft.selected_networks, scheduled: draft.scheduled?,
                            date: params[:date], time: params[:time], topic: params[:topic])
        flash.now[:alert] = error
        return render :show, status: :unprocessable_content
      end

      # ⚠️ One key for each post, made one time and outside the loop below. Each network gets its
      # own text, and all three must share the key of a post: Bluesky writes at that record key,
      # Mastodon sends it as its Idempotency-Key, and Threads keeps its media container below it.
      # Thus a Sidekiq retry replaces the same post and does not add a second one.
      keys = draft.posts.map { Bluesky.new_tid }
      at = draft.scheduled_at
      keep_photos(at)

      # ⚠️ Only the first post of each network is scheduled. That job adds the job of the post
      # below it when it succeeds, thus the rest of a thread needs no time of its own.
      draft.selected_networks.each do |network|
        payload = draft.payload(network, keys)
        job = SocialDraft::NETWORKS.fetch(network)[:job]
        at ? job.perform_at(at, payload) : job.perform_async(payload)
      end

      redirect_to social_path, status: :see_other, notice: queued_notice(at)
    end

    # GET /social/preview
    #
    # The card of a link, as JSON, for the preview on the page. ⚠️ The browser cannot read another
    # site by itself: the CSP of the admin has `connect-src :self`, and another host sends no CORS
    # header. Thus this app reads it.
    #
    # `OpenGraph#fetch` caches for 15 minutes, thus a preview also warms the cache that the post
    # job reads a moment later.
    def preview
      url = params[:url].to_s.strip
      return render json: { error: t("admin.social.errors.not_a_link") }, status: :unprocessable_content unless
        OpenGraph.http_url?(url)

      render json: social_preview.card_json(url)
    end

    # POST /social/preview/text
    #
    # The draft as each connected network will receive it, as JSON. It writes nothing, it adds no
    # job, and it calls no other service.
    #
    # ⚠️ It is a POST, and the two previews beside it are GET. A draft is as much as MAX_POSTS
    # posts of 300 characters and a mention map, thus a query string is the wrong shape for it.
    def preview_text
      render json: { networks: social_preview.networks }
    end

    # GET /social/preview/image
    #
    # Proxies the picture of a card.
    #
    # ⚠️ The browser cannot load the og:image directly, because the CSP of the admin has
    # `img-src :self`. Thus this action reads it and sends it from this host.
    #
    # ⚠️ The parameter is the URL of the page, and not of the picture. Thus a caller cannot name
    # any URL for this app to get: the picture is always the one that the og: tags of that page
    # name. `Bluesky#card_image` gives the same bytes that go up as the blob.
    def preview_image
      url = params[:url].to_s.strip
      return head :unprocessable_content unless OpenGraph.http_url?(url)

      image_url = OpenGraph.new.fetch(url).image_url
      return head :not_found if image_url.blank?

      picture = Bluesky.new.card_image(image_url)
      return head :not_found if picture.nil?

      send_data picture[:body], type: picture[:content_type], disposition: "inline"
    end

    private

    # The draft of this request. ⚠️ It is one object for the request: refer to the ⚠️ at the top.
    def draft
      @draft ||= SocialDraft.new(params, networks: social_networks)
    end

    def social_preview
      @social_preview ||= SocialPreview.new(
        draft: draft,
        photo_path: ->(id) { social_photo_path(id) },
        image_path: ->(url) { social_preview_image_path(url: url) }
      )
    end

    # The networks that this page can post to, in a stable order.
    #
    # ⚠️ Each answer comes from Redis, and no service makes an HTTP request.
    # `StandardSite#connected?` has that same rule, and its comment gives the reason: an upstream
    # failure must not go into the path of a page load.
    #
    # ⚠️ Each key of `SocialDraft::NETWORKS` needs a `<key>_status` method below.
    # @return [Array<SocialPresenter::Network>]
    def social_networks
      @social_networks ||= SocialDraft::NETWORKS.keys.map do |key|
        connected, account, notice = send(:"#{key}_status")
        SocialPresenter::Network.new(key: key, name: SocialDraft.network_name(key), connected: connected,
                                    account: account, notice: notice)
      end
    end

    # Each `*_status` method gives `[connected, account, notice]`: whether the row can take a post,
    # the name of the account, and the reason for a row that cannot. A nil notice gives the default
    # "Not connected." of the view.
    def bluesky_status
      service = StandardSite.new
      [ service.connected?, ("@#{service.handle}" if service.handle.present?), nil ]
    end

    def mastodon_status
      service = Mastodon.new
      [ service.connected?, service.handle, nil ]
    end

    # ⚠️ A Threads account with an expired token is connected and cannot post: `usable?` is the
    # check, and not `connected?`. Without that the job would raise for 24 hours.
    def threads_status
      service = Threads.new
      notice = t("admin.social.status.threads_expired") if service.expired?
      [ service.usable?, ("@#{service.username}" if service.username.present?), notice ]
    end

    # ⚠️ `alt_text:` is one env read, and no HTTP request, for the reason that #social_networks
    # gives.
    def presenter(**overrides)
      SocialPresenter.new(networks: social_networks, alt_text: AltText.configured?, **overrides)
    end

    # Gives each photo of the draft a TTL that outlasts the post and its retries.
    # @param at [ActiveSupport::TimeWithZone, nil] The moment of the post, or nil for now.
    def keep_photos(at)
      ids = draft.photo_ids
      return if ids.empty?

      wait = at ? at - Time.current : 0
      SocialPhotos.new.keep(ids, (wait + PHOTO_KEEP_MARGIN).to_i)
    end

    # @param at [ActiveSupport::TimeWithZone, nil] The moment, or nil to post now.
    def queued_notice(at)
      names = draft.names_of(draft.selected_networks)
      return t("admin.social.flash.scheduled", networks: names, at: format_schedule(at)) if at

      t("admin.social.flash.sent", networks: names)
    end

    # The moment in the zone that the owner picked it in. The zone of the server would read as the
    # wrong time.
    def format_schedule(at)
      Time.use_zone(draft.schedule_zone) { at.in_time_zone.strftime("%B %-e at %-I:%M %p %Z") }
    end
  end
end
