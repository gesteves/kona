module Admin
  # The Share composer: it picks a published entry, drafts one body, and adds a SharePostJob for
  # the networks that the owner selected.
  #
  # ⚠️ Only Bluesky posts today. `SharePostJob::SUPPORTED` names the networks that work, and the
  # notice says which ones the job skips.
  class ShareController < BaseController
    # GET /share
    #
    # ⚠️ The page renders with no account connected, and each row is then disabled. It is a draft
    # screen, thus it must be available to look at and to change before an account exists.
    def show
      @share = presenter
    end

    # POST /share
    #
    # It checks the draft, then adds the job. ⚠️ It makes the record key **here** and gives it to
    # the job. `Bluesky#post!` writes with `putRecord` at that key, thus a Sidekiq retry replaces
    # the same post and does not add a second one.
    def create
      error = validation_error

      # ⚠️ It renders again and does not redirect. A redirect would lose the words that the owner
      # wrote, and the draft is the expensive part of this page.
      if error
        @share = presenter(body: params[:body], article_url: params[:article_url],
                           selected: selected_networks, scheduled: scheduled?,
                           date: params[:date], time: params[:time])
        flash.now[:alert] = error
        return render :show, status: :unprocessable_content
      end

      args = [ Bluesky.new_tid, article_url, params[:body].to_s, selected_networks ]
      at = scheduled_at
      at ? SharePostJob.perform_at(at, *args) : SharePostJob.perform_async(*args)

      redirect_to share_path, status: :see_other, notice: queued_notice(at)
    end

    private

    # The networks that this page can post to, in a stable order.
    #
    # ⚠️ Each answer comes from Redis, and no service makes an HTTP request.
    # `StandardSite#connected?` has that same rule, and its comment gives the reason: an upstream
    # failure must not go into the path of a page load.
    # @return [Array<SharePresenter::Network>]
    def social_networks
      @social_networks ||= begin
        bluesky = StandardSite.new
        mastodon = Mastodon.new
        threads = Threads.new

        [
          SharePresenter::Network.new(
            key: "bluesky", name: "Bluesky", connected: bluesky.connected?,
            account: ("@#{bluesky.handle}" if bluesky.handle.present?)
          ),
          SharePresenter::Network.new(
            key: "mastodon", name: "Mastodon", connected: mastodon.connected?,
            account: mastodon.handle
          ),
          SharePresenter::Network.new(
            key: "threads", name: "Threads", connected: threads.connected?,
            account: ("@#{threads.username}" if threads.username.present?)
          )
        ]
      end
    end

    # @return [SharePresenter]
    def presenter(**overrides)
      SharePresenter.new(networks: social_networks, **overrides)
    end

    # @return [Array<String>] The keys that the owner ticked, and only the ones that this app knows.
    def selected_networks
      @selected_networks ||= Array(params[:networks]).map(&:to_s) & social_networks.map(&:key)
    end

    # The link to share. ⚠️ It is not always an article of this site: the field takes any URL, and
    # the card of the post comes from the og: tags of that page.
    # @return [String]
    def article_url
      params[:article_url].to_s.strip
    end

    # @return [String, nil] The reason to refuse, or nil when the draft is good.
    def validation_error
      return "Paste a link to share." unless OpenGraph.new.http_url?(article_url)
      return "Write something to post." if params[:body].blank?
      unless Bluesky.valid_post_length?(params[:body])
        return "That post is #{Bluesky.post_length(params[:body])} characters. " \
               "The limit is #{Bluesky::MAX_GRAPHEMES}."
      end
      return "Pick at least one place to post it." if selected_networks.empty?

      schedule_error
    end

    # @return [Boolean] True when the owner opened the schedule fields.
    def scheduled? = ActiveModel::Type::Boolean.new.cast(params[:schedule]).present?

    # @return [String, nil] The reason to refuse the schedule, or nil.
    def schedule_error
      return nil unless scheduled?
      return "Pick a date and a time to schedule it." if scheduled_at.blank?
      return "Pick a time in the future." if scheduled_at <= Time.current

      # ⚠️ There is no limit on how far ahead this can be. The owner asked for that: a post about a
      # race can wait for the race. The job then sits in the scheduled set of Sidekiq until it runs.
      nil
    end

    # The moment that the two fields name, in the zone that the browser sent.
    #
    # ⚠️ A date and a time carry **no zone**. The browser writes its own IANA id into a hidden
    # field, thus "9:00" has one meaning. That is the difference from the Republish dialog, which
    # takes minutes from now for exactly this reason. With no JavaScript the field is empty, and
    # `TIME_ZONE` is the fallback.
    # @return [ActiveSupport::TimeWithZone, nil] The moment, or nil when a field is empty or has a
    #   value that cannot be read.
    def scheduled_at
      return @scheduled_at if defined?(@scheduled_at)

      @scheduled_at = parse_scheduled_at
    end

    # @return [ActiveSupport::TimeWithZone, nil]
    def parse_scheduled_at
      return nil unless scheduled?

      date = params[:date].to_s.strip
      time = params[:time].to_s.strip
      return nil if date.blank? || time.blank?

      Time.use_zone(schedule_zone) { Time.zone.parse("#{date} #{time}") }
    rescue ArgumentError
      nil
    end

    # ⚠️ It checks the value against the zones that Rails knows. That field comes from the browser,
    # thus a value with a mistake must give the fallback and never an exception.
    # @return [String] An IANA timezone id.
    def schedule_zone
      zone = params[:time_zone].to_s.strip
      ActiveSupport::TimeZone[zone] ? zone : TimeZoneResolver.default
    end

    # @param at [ActiveSupport::TimeWithZone, nil] The moment, or nil to post now.
    # @return [String] The notice, which names each network that the job cannot send to yet.
    def queued_notice(at)
      skipped = selected_networks - SharePostJob::SUPPORTED
      posting = selected_networks & SharePostJob::SUPPORTED
      notice =
        if posting.empty?
          "Nothing to post yet."
        elsif at
          "Scheduled a post to #{to_sentence(posting)} for #{format_schedule(at)}."
        else
          "Queued a post to #{to_sentence(posting)}."
        end
      return notice if skipped.empty?

      "#{notice} #{to_sentence(skipped)} #{skipped.one? ? 'isn\'t' : 'aren\'t'} wired up yet."
    end

    # The moment in the words of the owner, in the zone that they picked it in. To answer in the
    # zone of the server would read as the wrong time.
    # @param at [ActiveSupport::TimeWithZone]
    # @return [String]
    def format_schedule(at)
      Time.use_zone(schedule_zone) { at.in_time_zone.strftime("%B %-e at %-I:%M %p %Z") }
    end

    # @param keys [Array<String>] Network keys.
    # @return [String] Their names, in a sentence.
    def to_sentence(keys)
      social_networks.select { |network| keys.include?(network.key) }.map(&:name).to_sentence
    end
  end
end
