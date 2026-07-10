# Fetches the songs scrobbled to Last.fm during a workout, for the activity description's
# 🎧 top-artists line. Uses a username + API key (no OAuth); no-ops when unconfigured.
class Lastfm < ApplicationService
  LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/"

  # Buffer added to the pre-start side of the workout window when querying Last.fm.
  # Captures songs scrobbled before the workout that may have still been playing when it
  # started; their actual overlap is then verified via track.getInfo.
  WINDOW_BUFFER = 10.minutes

  def initialize
    @username = ENV["LASTFM_USERNAME"]
    @api_key = ENV["LASTFM_API_KEY"]
  end

  # @return [Boolean] Whether Last.fm credentials are configured.
  def configured?
    @username.present? && @api_key.present?
  end

  # Fetches songs played during a time window, in chronological order. Drops "now playing"
  # entries (which have no scrobble date). The query is widened 10 minutes before the start
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

  # @return [Array<Hash>] Raw track hashes from user.getrecenttracks (extended=1 adds the
  #   loved flag and full artist names).
  # @raise [RuntimeError] when Last.fm returns an error body.
  def recent_tracks(from_sec, to_sec, limit: 200)
    response = get_json!(
      LASTFM_API_URL,
      query: {
        method: "user.getrecenttracks",
        user: @username,
        api_key: @api_key,
        format: "json",
        limit: limit,
        from: from_sec,
        to: to_sec,
        extended: 1
      }
    )
    raise "Last.fm error #{response[:error]}: #{response[:message]}" if response[:error].present?

    tracks = response.dig(:recenttracks, :track)
    return [] if tracks.blank?

    tracks.is_a?(Array) ? tracks : [tracks]
  end

  # A track's duration in seconds via track.getInfo, or nil when Last.fm doesn't have one
  # (the field is missing or "0" for sparsely-cataloged tracks).
  # @return [Float, nil]
  def track_duration_seconds(artist, track)
    response = get_json!(
      LASTFM_API_URL,
      query: {
        method: "track.getInfo",
        artist: artist,
        track: track,
        api_key: @api_key,
        format: "json",
        autocorrect: 1
      }
    )
    return if response[:error].present?

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

    duration = begin
      track_duration_seconds(song[:artist], song[:name])
    rescue StandardError
      return true
    end
    return true if duration.nil?

    song[:played_at] + duration > start_time
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
