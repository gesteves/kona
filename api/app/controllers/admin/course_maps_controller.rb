# Sidekiq::ProcessSet, for the "does a process do the queued jobs?" check below. The
# `require "sidekiq/web"` in the initializer also loads it, but no code here must depend on that.
require "sidekiq/api"

module Admin
  # Renders the GPX tracks as static map cover images. It is a front end for the Mapbox Data
  # Workbench: upload one or more tracks, wait for Mapbox to publish each one as a vector tileset,
  # then set the frame and the style of one track and download the PNG.
  class CourseMapsController < BaseController
    # The maximum size of one upload. The parse of the GPX occurs in the request, thus these
    # values limit the memory of the parse and its time against the 20-second request budget.
    MAX_FILES = 10
    MAX_BYTES = 25.megabytes

    # GET /course-maps
    def index
      @tracks = library.all.map { |record| present(record) }
      @configured = MapboxTileset.configured?
      @worker_running = worker_running? if @tracks.any?(&:processing?)
    end

    # POST /course-maps
    def create
      # The code removes each item that is not an upload and does not examine it. An empty file
      # field posts a blank string, and a request that a person makes can post any content.
      files = Array(params[:gpx_files]).grep(ActionDispatch::Http::UploadedFile)
      return redirect_to(course_maps_path, status: :see_other, alert: t("admin.course_maps.flash.no_files")) if files.empty?

      error = rejection_reason(files)
      return redirect_to(course_maps_path, status: :see_other, alert: error) if error

      accepted, failures = ingest(files)

      redirect_to course_maps_path, status: :see_other, **upload_flash(accepted, failures)
    end

    # GET /course-maps/status
    #
    # The index page reads this during an upload. It is small, on purpose: it returns the
    # statuses, not the records, and the page reads it each few seconds.
    def status
      render json: library.statuses
    end

    # GET /course-maps/:id
    #
    # The settings in the query string replace the stored settings. Thus the path with no
    # JavaScript, where you submit the form and get a new page, shows the same render as the live
    # preview.
    def show
      record = find_track!
      return if performed?

      @track = present(record.merge("settings" => render_settings(record)))
      @icons = StaticMap.icon_options
      @styles = StaticMap.style_options
    end

    # PATCH /course-maps/:id
    #
    # Saves each change to the render settings. Thus a track that you open again has the settings
    # from the last session. The preview controller calls this, and not a form submission.
    def update
      record = library.update_settings(params[:id], settings_params)
      return head :not_found if record.nil?

      head :no_content
    end

    # DELETE /course-maps/:id
    def destroy
      record = find_track!
      return if performed?

      MapboxTileset.new.destroy!(record["id"]) if MapboxTileset.configured?
      library.delete(record["id"])

      redirect_to course_maps_path, status: :see_other, notice: t("admin.course_maps.flash.deleted", title: record["title"])
    rescue StandardError => e
      # The log holds the message of Mapbox. The page names the class only.
      Rails.logger.error("Maps: could not delete #{params[:id]} (#{e.class}: #{e.message})")
      redirect_to course_maps_path, status: :see_other, alert: t("admin.course_maps.flash.delete_failed", error: e.class.name)
    end

    # GET /course-maps/:id/preview
    #
    # ⚠️ This is a proxy, and not a link. The Static Images API takes its token as a query
    # parameter. Thus an <img> that points at Mapbox would give a tilesets:write credential to the
    # browser.
    #
    # This renders at 2x, as the download does, and not at a smaller preview size. The API bills
    # for each request and not for each pixel, thus a smaller render saves nothing important. The
    # zoom dialog also shows this same image at its full width, and at 1x that is half the pixels
    # that a retina screen needs. The cost is the bandwidth for each change, and the debounce
    # already limits that.
    def preview
      send_render(disposition: "inline")
    end

    # GET /course-maps/:id/download
    def download
      send_render(disposition: "attachment")
    end

    private

    def library
      @library ||= TrackLibrary.new
    end

    # Tells if a Sidekiq process runs and can do the queued jobs.
    #
    # ⚠️ The code reads this only during a publish, and only to give the cause of a row that does
    # not change. This is the one admin page whose main function needs the worker. Without this
    # check, a track stays at "Processing" for all time and nothing says why. That is also why
    # `worker` is not optional in .overmind.env. In production an empty set means that the worker
    # machine is down.
    def worker_running?
      Sidekiq::ProcessSet.new.size.positive?
    rescue StandardError => e
      Rails.logger.warn("Maps: could not read Sidekiq's process set (#{e.class}: #{e.message})")
      true # Don't cry wolf if the check itself is what's broken.
    end

    # Loads the track that the URL names. If the track is gone, it redirects.
    # @return [Hash, nil] The record, or nil after a redirect.
    def find_track!
      record = library.find(params[:id])
      return record if record

      redirect_to course_maps_path, status: :see_other, alert: t("admin.course_maps.flash.gone")
      nil
    end

    # The image URLs contain the settings that the page renders with. Thus a page with no
    # JavaScript and the live preview agree. The preview controller changes both when it starts.
    def present(record)
      id = record["id"]
      query = settings_params.any? ? { settings: settings_params } : {}

      MapTrackPresenter.new(
        record: record,
        show_path: course_map_path(id),
        preview_path: course_map_preview_path(id, query),
        download_path: course_map_download_path(id, query),
        delete_path: course_map_path(id)
      )
    end

    # @return [String, nil] The cause of a refusal of the batch, or nil if the batch is correct.
    def rejection_reason(files)
      return t("admin.course_maps.flash.too_many", count: MAX_FILES) if files.length > MAX_FILES

      bad = files.reject { |file| File.extname(file.original_filename.to_s).casecmp?(".gpx") }
      return t("admin.course_maps.flash.not_gpx", files: bad.map(&:original_filename).to_sentence) if bad.any?

      total = files.sum { |file| file.size.to_i }
      if total > MAX_BYTES
        return t("admin.course_maps.flash.too_large",
                 size: ActiveSupport::NumberHelper.number_to_human_size(total),
                 limit: ActiveSupport::NumberHelper.number_to_human_size(MAX_BYTES))
      end

      nil
    end

    # Parses each upload and adds it to the queue. A file that the code cannot parse gives a
    # message and does not raise. Thus one bad track in a batch does not remove the good tracks.
    # @return [Array(Array<String>, Array<String>)] The accepted titles and the refusal messages.
    def ingest(files)
      accepted = []
      failures = []

      files.each do |file|
        track = GpxTrack.new(file.tempfile, fallback_name: File.basename(file.original_filename.to_s, ".*"))
        MapTilesetJob.perform_async(library.stage(track))
        accepted << track.title
      rescue GpxTrack::ParseError => e
        failures << t("admin.course_maps.flash.unreadable", file: file.original_filename, error: e.message)
      end

      [ accepted, failures ]
    end

    def upload_flash(accepted, failures)
      return { alert: failures.to_sentence } if accepted.empty?

      notice = t("admin.course_maps.flash.uploading", files: accepted.to_sentence)
      failures.any? ? { notice: notice, alert: failures.to_sentence } : { notice: notice }
    end

    def settings_params
      raw = params[:settings]
      return {} unless raw.is_a?(ActionController::Parameters)

      raw.permit(*TrackLibrary.setting_keys).to_h
    end

    # Renders with Mapbox and sends the PNG back as a stream.
    #
    # A failure gives a status and not a redirect: an <img> and a download link get these two
    # actions, and a redirect to an HTML page becomes a broken image.
    def send_render(disposition:)
      record = library.find(params[:id])
      return head :not_found if record.nil?
      return head :conflict unless record["status"] == "ready"

      map = StaticMap.new(track: record, settings: render_settings(record))
      send_data map.render, type: "image/png", disposition: disposition, filename: map.filename
    # ⚠️ This is the same group of errors that StaticMap#get_with_retries catches, because that
    # method raises the original exception again after the last attempt and does not put it in
    # another error. A rescue of RenderError alone let a Mapbox timeout become a 500 that nothing
    # caught. Bugsnag then reported a crash, and an <img> got that 500. These two actions exist to
    # give a clean status code instead.
    rescue StaticMap::RenderError, Net::OpenTimeout, Net::ReadTimeout, SocketError,
           Errno::ECONNRESET, HTTParty::Error => e
      Rails.logger.error("Maps: render failed for #{params[:id]} (#{e.class}: #{e.message})")
      head :bad_gateway
    end

    # The query parameters replace the stored settings. Thus the preview can change with the form
    # and does not need a save first.
    def render_settings(record)
      (record["settings"] || {}).merge(settings_params)
    end
  end
end
