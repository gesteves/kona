# Fetches the songs scrobbled to Last.fm during a workout, for the activity description's
# 🎧 top-artists line. Uses a username + API key (no OAuth); no-ops when unconfigured.
class Lastfm < ApplicationService
  LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/"

  # Buffer added to the pre-start side of the workout window when querying Last.fm.
  # Captures songs scrobbled before the workout that may have still been playing when it
  # started; their actual overlap is then verified via track.getInfo.
  WINDOW_BUFFER = 5.minutes

  # How many recent tracks to request per user.getrecenttracks call. Generous for any single
  # workout window (200 short tracks is ~10+ hours), so no pagination is needed.
  RECENT_TRACKS_LIMIT = 200

  def initialize
    @username = ENV["LASTFM_USERNAME"]
    @api_key = ENV["LASTFM_API_KEY"]
  end

  # @return [Boolean] Whether Last.fm credentials are configured.
  def configured?
    @username.present? && @api_key.present?
  end

  # Fetches songs played during a time window, in chronological order. Drops "now playing"
  # entries (which have no scrobble date). The query is widened 5 minutes before the start
  # to catch songs that began before the workout but were still playing when it started;
  # each pre-start scrobble is kept only if its track.getInfo duration overlaps the start —
  # kept conservatively when the duration is unknown or the lookup fails. Last.fm's scrobble
  # timestamp is the track's *start* time, so anything after end_time never overlapped.
  # @param start_time [Time]
  # @param end_time [Time]
  # @return [Array<Hash>] Songs ({name:, artist:, album:, played_at:, loved:, url:}).
  def played_songs_during(start_time, end_time)
    return [] unless configured?

    from_sec = (start_time - WINDOW_BUFFER).to_i
    to_sec = end_time.to_f.ceil

    songs = recent_tracks(from_sec, to_sec)
            .select { |track| track.dig(:date, :uts).present? }
            .map { |track| normalize_track(track) }
            .select { |song| song[:played_at] <= end_time }

    songs.select { |song| overlaps_start?(song, start_time) }
         .sort_by { |song| song[:played_at] }
  end

  private

  # GETs a Last.fm API method, merging in the shared credentials/format params. Last.fm signals
  # failures with an HTTP 200 carrying an error body, so that's raised here (not by get_json!).
  # When retryable: true, transient transport failures (5xx/timeouts, which get_json! raises as
  # HttpError) are retried with backoff; Last.fm error bodies come back as 200s and so are
  # never retried — they're permanent and raise immediately.
  # @raise [RuntimeError] on an error body, an empty body, or an exhausted retry.
  def lastfm_get(method, retryable: false, **params)
    query = { method: method, api_key: @api_key, format: "json", **params }
    response = retryable ? with_retries { get_json!(LASTFM_API_URL, query: query) } : get_json!(LASTFM_API_URL, query: query)
    raise "Last.fm #{method} request failed" if response.nil?
    raise "Last.fm error #{response[:error]}: #{response[:message]}" if response[:error].present?

    response
  end

  # @return [Array<Hash>] Raw track hashes from user.getrecenttracks (extended=1 adds the
  #   loved flag and full artist names).
  # @raise [RuntimeError] when the fetch fails (after retries) or Last.fm returns an error body.
  def recent_tracks(from_sec, to_sec)
    response = lastfm_get(
      "user.getrecenttracks",
      retryable: true,
      user: @username,
      limit: RECENT_TRACKS_LIMIT,
      from: from_sec,
      to: to_sec,
      extended: 1
    )

    tracks = response.dig(:recenttracks, :track)
    return [] if tracks.blank?

    tracks.is_a?(Array) ? tracks : [tracks]
  end

  # A track's duration in seconds via track.getInfo, or nil when Last.fm doesn't have one
  # (the field is missing or "0" for sparsely-cataloged tracks).
  # @return [Float, nil]
  # @raise [RuntimeError] when Last.fm returns an error body (caller keeps the song conservatively).
  def track_duration_seconds(artist, track)
    response = lastfm_get("track.getInfo", artist: artist, track: track, autocorrect: 1)

    duration_ms = response.dig(:track, :duration).to_f
    return if duration_ms <= 0

    duration_ms / 1000.0
  end

  # Whether a song was (or may have been) still playing at the workout's start. Songs
  # scrobbled at/after the start trivially overlap; pre-start scrobbles are checked against
  # their track duration, kept conservatively on unknown duration or a lookup error —
  # better a false positive than a silent drop.
  def overlaps_start?(song, start_time)
    return true if song[:played_at] >= start_time

    duration = track_duration_seconds(song[:artist], song[:name])
    return true if duration.nil?

    song[:played_at] + duration > start_time
  rescue StandardError
    true # conservative keep when the duration lookup fails — better a false positive than a drop
  end

  # @return [Hash] The normalized song.
  def normalize_track(track)
    {
      name: track[:name].to_s,
      played_at: Time.at(track.dig(:date, :uts).to_i).utc,
      url: track[:url],
      album: track.dig(:album, :"#text").to_s,
      artist: track.dig(:artist, :"#text").presence || track.dig(:artist, :name).to_s,
      loved: track[:loved] == "1"
    }
  end
end
