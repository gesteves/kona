# Sidekiq::ProcessSet, for the "is anything draining the queue?" check below. It arrives anyway via
# the initializer's `require "sidekiq/web"`, but nothing here should depend on that.
require "sidekiq/api"

module Admin
  # Renders GPX tracks as static map cover images, as a front-end over Mapbox's Data Workbench:
  # upload one or more tracks, wait for Mapbox to publish each as a vector tileset, then tune the
  # framing and styling of one and download the PNG.
  class MapsController < BaseController
    # How much of an upload we'll take at once. The GPX is parsed in-request, so these bound both
    # the memory the parse touches and the time it takes against the 20-second request budget.
    MAX_FILES = 10
    MAX_BYTES = 25.megabytes

    # GET /maps
    def index
      @tracks = library.all.map { |record| present(record) }
      @configured = MapboxTileset.configured?
      @worker_running = worker_running? if @tracks.any?(&:processing?)
    end

    # POST /maps
    def create
      # Anything that isn't an actual upload is dropped rather than inspected — an empty file field
      # posts a blank string, and a hand-rolled request can post whatever it likes.
      files = Array(params[:gpx_files]).grep(ActionDispatch::Http::UploadedFile)
      return redirect_to(maps_path, status: :see_other, alert: "Choose at least one GPX file.") if files.empty?

      error = rejection_reason(files)
      return redirect_to(maps_path, status: :see_other, alert: error) if error

      accepted, failures = ingest(files)

      redirect_to maps_path, status: :see_other, **upload_flash(accepted, failures)
    end

    # GET /maps/status
    #
    # Polled by the index page while an upload is in flight. Deliberately tiny — it returns
    # statuses, not records, and is hit every few seconds.
    def status
      render json: library.statuses
    end

    # GET /maps/:id
    #
    # Query-string settings override the stored ones, so the no-JS path (submit the form, get a
    # fresh page) shows the same render the live preview would.
    def show
      record = find_track!
      return if performed?

      @track = present(record.merge("settings" => render_settings(record)))
      @icons = StaticMap::MARKER_ICONS
      @styles = StaticMap::STYLE_PRESETS
    end

    # PATCH /maps/:id
    #
    # Saves the render settings as they're tweaked, so reopening a track picks up where the last
    # session left off. Called from the preview controller, not from a form submission.
    def update
      record = library.update_settings(params[:id], settings_params)
      return head :not_found if record.nil?

      head :no_content
    end

    # DELETE /maps/:id
    def destroy
      record = find_track!
      return if performed?

      MapboxTileset.new.destroy!(record["id"]) if MapboxTileset.configured?
      library.delete(record["id"])

      redirect_to maps_path, status: :see_other, notice: "#{record['title']} deleted."
    rescue StandardError => e
      Rails.logger.error("Maps: could not delete #{params[:id]} (#{e.class}: #{e.message})")
      redirect_to maps_path, status: :see_other, alert: "Couldn't delete that track from Mapbox: #{e.message}"
    end

    # GET /maps/:id/preview
    #
    # ⚠️ Proxied rather than linked. The Static Images API takes its token as a query parameter, so
    # an <img> pointed straight at Mapbox would hand the browser a tilesets:write credential.
    #
    # Rendered at 2x like the download, not at some cheaper preview size: the API bills per request
    # rather than per pixel, so a smaller render saves nothing that matters, and the zoom dialog
    # shows this same image at up to its full width — at 1x that is half the pixels a retina screen
    # wants. The cost is bandwidth per tweak, which the debounce already bounds.
    def preview
      send_render(disposition: "inline")
    end

    # GET /maps/:id/download
    def download
      send_render(disposition: "attachment")
    end

    private

    def library
      @library ||= TrackLibrary.new
    end

    # Whether any Sidekiq process is alive to drain the queue.
    #
    # ⚠️ Checked only when something is publishing, and only to explain a stuck row. This is the
    # one admin page whose core function needs the worker, so without this a track spins on
    # "Processing" forever with nothing anywhere saying why — which is also why `worker` is no
    # longer opt-in in .overmind.env. In production an empty set means the worker machine is down.
    def worker_running?
      Sidekiq::ProcessSet.new.size.positive?
    rescue StandardError => e
      Rails.logger.warn("Maps: could not read Sidekiq's process set (#{e.class}: #{e.message})")
      true # Don't cry wolf if the check itself is what's broken.
    end

    # Loads the track named in the URL, redirecting if it's gone.
    # @return [Hash, nil] The record, or nil once a redirect has been performed.
    def find_track!
      record = library.find(params[:id])
      return record if record

      redirect_to maps_path, status: :see_other, alert: "That track is no longer in the library."
      nil
    end

    # The image URLs carry the settings the page is rendering with, so a no-JS page and the live
    # preview agree. The preview controller rewrites both once it takes over.
    def present(record)
      id = record["id"]
      query = settings_params.any? ? { settings: settings_params } : {}

      MapTrackPresenter.new(
        record: record,
        show_path: map_path(id),
        preview_path: map_preview_path(id, query),
        download_path: map_download_path(id, query),
        delete_path: map_path(id)
      )
    end

    # @return [String, nil] Why the batch was refused, or nil if it's fine.
    def rejection_reason(files)
      return "Upload at most #{MAX_FILES} files at a time." if files.length > MAX_FILES

      bad = files.reject { |file| File.extname(file.original_filename.to_s).casecmp?(".gpx") }
      return "#{bad.map(&:original_filename).to_sentence} isn't a GPX file." if bad.any?

      total = files.sum { |file| file.size.to_i }
      return "That's #{ActiveSupport::NumberHelper.number_to_human_size(total)} of GPX; the limit is #{ActiveSupport::NumberHelper.number_to_human_size(MAX_BYTES)}." if total > MAX_BYTES

      nil
    end

    # Parses each upload and queues it. A file that won't parse is reported rather than raising, so
    # one bad track in a batch doesn't lose the good ones.
    # @return [Array(Array<String>, Array<String>)] Accepted titles and rejection messages.
    def ingest(files)
      accepted = []
      failures = []

      files.each do |file|
        track = GpxTrack.new(file.tempfile, fallback_name: File.basename(file.original_filename.to_s, ".*"))
        MapTilesetJob.perform_async(library.stage(track))
        accepted << track.title
      rescue GpxTrack::ParseError => e
        failures << "#{file.original_filename}: #{e.message}"
      end

      [ accepted, failures ]
    end

    def upload_flash(accepted, failures)
      return { alert: failures.to_sentence } if accepted.empty?

      notice = "Uploading #{accepted.to_sentence} to Mapbox. This takes a minute."
      failures.any? ? { notice: notice, alert: failures.to_sentence } : { notice: notice }
    end

    def settings_params
      raw = params[:settings]
      return {} unless raw.is_a?(ActionController::Parameters)

      raw.permit(*TrackLibrary.setting_keys).to_h
    end

    # Renders through Mapbox and streams the PNG back.
    #
    # Failures answer with a status rather than a redirect: these two actions are fetched by an
    # <img> and a download link, where a redirect to an HTML page renders as a broken image.
    def send_render(disposition:)
      record = library.find(params[:id])
      return head :not_found if record.nil?
      return head :conflict unless record["status"] == "ready"

      map = StaticMap.new(track: record, settings: render_settings(record))
      send_data map.render, type: "image/png", disposition: disposition, filename: map.filename
    rescue StaticMap::RenderError => e
      Rails.logger.error("Maps: render failed for #{params[:id]} (#{e.message})")
      head :bad_gateway
    end

    # Query parameters win over the stored settings, so the preview can update as the form changes
    # without saving first.
    def render_settings(record)
      (record["settings"] || {}).merge(settings_params)
    end
  end
end
