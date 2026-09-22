# Sidekiq::ProcessSet, for the "does a process do the queued jobs?" check below. The
# `require "sidekiq/web"` in the initializer also loads it, but no code here must depend on that.
require "sidekiq/api"

module Admin
  # The media uploader: it puts one or more images into Contentful as published assets.
  #
  # The owner picks the files, each one becomes a tile with a thumbnail, a title, and an alt text
  # field, and a Generate control asks Claude for that text. The submit adds one
  # `ContentfulAssetJob` for each tile. The alt text becomes `fields.description` of the asset,
  # which is the field that `web/` renders as the `alt` of an image.
  #
  # ⚠️ The tiles have NO order: an asset stands by itself. Thus this page has no grip and no drag,
  # and it is different from the photo composer of the Social media page in that one way.
  class ContentfulUploadsController < BaseController
    # The most tiles of one submit. It is a guard against a runaway form, and not a limit of
    # Contentful.
    MAX_FILES = 25

    # GET /contentful/uploads
    def index
      @uploads = library.all.map { |record| ContentfulUploadPresenter.new(record) }
      @configured = ContentfulManagement.configured?
      @alt_text = AltText.configured?
      @worker_running = worker_running? if @uploads.any?(&:processing?)
    end

    # POST /contentful/uploads
    def create
      unless ContentfulManagement.configured?
        return redirect_to(contentful_uploads_path, status: :see_other,
                           alert: t("admin.contentful_uploads.flash.unconfigured"))
      end

      files = submitted_files
      if files.empty?
        return redirect_to(contentful_uploads_path, status: :see_other,
                           alert: t("admin.contentful_uploads.flash.no_files"))
      end
      if files.length > MAX_FILES
        return redirect_to(contentful_uploads_path, status: :see_other,
                           alert: t("admin.contentful_uploads.flash.too_many", count: MAX_FILES))
      end

      accepted, expired = ingest(files)

      redirect_to contentful_uploads_path, status: :see_other, **submit_flash(accepted, expired)
    end

    # GET /contentful/uploads/status
    #
    # The index page reads this while a file publishes. It is small, on purpose: it returns the
    # statuses, not the records, and the page reads it each few seconds.
    def status
      render json: library.statuses
    end

    private

    def library
      @library ||= UploadLibrary.new
    end

    # The tiles of the form, in order.
    #
    # ⚠️ The form sends THREE flat arrays — `files[ids][]`, `files[titles][]`, and
    # `files[alts][]` — and they match by POSITION. Thus this pairs them first and drops a whole
    # triple after that: a tile whose upload is still out sends an empty id, and a drop of the id
    # alone would move each title and each alt text after it by one.
    # ⚠️ They are three arrays and NOT `files[][id]`. Rack makes a new hash for that shape only
    # when a key repeats, thus one field that a browser does not submit would join two tiles into
    # one, and no check would show it.
    # @return [Array<Hash>] `[{ id:, title:, alt: }, …]`
    def submitted_files
      ids = Array(params.dig(:files, :ids)).map(&:to_s)
      titles = Array(params.dig(:files, :titles)).map(&:to_s)
      alts = Array(params.dig(:files, :alts)).map(&:to_s)

      ids.each_with_index.filter_map do |id, index|
        next unless StagedUpload.id?(id)

        { id: id, title: titles[index].to_s.strip, alt: alts[index].to_s.strip }
      end
    end

    # Records each tile and adds its job to the queue. A tile whose staged file expired gives a
    # message and stops nothing: one stale tile in a batch must not refuse the other ones.
    # @return [Array(Array<String>, Array<String>)] The accepted names and the expired names.
    def ingest(files)
      staged_upload = StagedUpload.new
      accepted = []
      expired = []

      files.each do |file|
        staged = staged_upload.fetch(file[:id])
        if staged.nil?
          expired << file[:title].presence || file[:id]
          next
        end

        # The file name is the fallback title, as it is at the pick. A tile whose title the owner
        # emptied must still make an asset with a name.
        title = file[:title].presence || File.basename(staged[:file_name], ".*")
        library.stage(id: file[:id], title: title, alt: file[:alt], file_name: staged[:file_name])
        ContentfulAssetJob.perform_async(file[:id])
        accepted << title
      end

      [ accepted, expired ]
    end

    def submit_flash(accepted, expired)
      alert = t("admin.contentful_uploads.flash.expired", files: expired.to_sentence) if expired.any?
      return { alert: alert } if accepted.empty?

      notice = t("admin.contentful_uploads.flash.publishing", count: accepted.length,
                 files: accepted.to_sentence)
      alert ? { notice: notice, alert: alert } : { notice: notice }
    end

    # ⚠️ This page needs the Sidekiq worker, as the Course maps page does: a file stays at
    # "Processing" until the job publishes it.
    def worker_running?
      Sidekiq::ProcessSet.new.size.positive?
    rescue StandardError => e
      Rails.logger.warn("Media: could not read Sidekiq's process set (#{e.class}: #{e.message})")
      true # Don't cry wolf if the check itself is what's broken.
    end
  end
end
