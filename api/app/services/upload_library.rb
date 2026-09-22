require "time"

# The record of each file that the media uploader sent to Contentful, and what became of it.
#
# The page cannot say "it worked" at the submit: `ContentfulAssetJob` does the work, and the
# processing of a file at Contentful is asynchronous. Thus the job writes its result here and the
# page reads it again each few seconds, as the Maps page does with its tilesets.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# ⚠️ This is a short HISTORY and not a durable record. The asset itself is in Contentful, thus
# nothing here is the only copy of anything, and `#stage` prunes.
class UploadLibrary
  # The Redis hash: the field is the id of the staged file, and the value is the JSON record.
  REDIS_KEY = "contentful:uploads".freeze

  # ⚠️ "processing" is the word that `job_status_controller.js` compares against. Do not change it
  # in one place only.
  STATUSES = %w[processing published failed].freeze

  # The most records that stay, and how long one stays.
  MAX_ENTRIES = 50
  MAX_AGE = 7.days

  # Records one file at the submit, before the job runs.
  # @param id [String] The id of the staged file. It is also the id of this record.
  # @param title [String] `fields.title` of the asset.
  # @param alt [String] `fields.description` of the asset.
  # @param file_name [String] The name of the file that the owner picked.
  # @return [String] The id.
  def stage(id:, title:, alt:, file_name:)
    write(id, {
      "id" => id,
      "title" => title.to_s,
      "alt" => alt.to_s,
      "file_name" => file_name.to_s,
      "status" => "processing",
      "asset_id" => nil,
      "error" => nil,
      "uploaded_at" => Time.now.utc.iso8601
    })
    prune
    id
  end

  # All the records, the newest first.
  # @return [Array<Hash>]
  def all
    records.read_all.values.sort_by { |record| record["uploaded_at"].to_s }.reverse
  end

  # @param id [String]
  # @return [Hash, nil]
  def find(id)
    records.read(id)
  end

  # id => status, for the poll endpoint of the page. It is not the full records, on purpose,
  # because the page gets this each few seconds while a file publishes.
  # @return [Hash{String => String}]
  def statuses
    all.to_h { |record| [ record["id"], record["status"].to_s ] }
  end

  # Changes one record in place.
  # @param id [String]
  # @param changes [Hash] The changes to put on top of the stored record.
  # @return [Hash, nil] The new record, or nil if the record is gone.
  def update(id, changes)
    record = find(id)
    return nil if record.nil?

    write(id, record.merge(changes.transform_keys(&:to_s)))
  end

  # @param id [String]
  # @return [Boolean] True if the code removed a record.
  def delete(id)
    records.delete(id).positive?
  end

  # @return [Integer]
  def count
    records.count
  end

  private

  def records
    @records ||= JsonHashStore.new(REDIS_KEY)
  end

  def write(id, record)
    records.write(id, record)
  end

  # Removes each record past MAX_AGE, and then the oldest above MAX_ENTRIES. Both limits apply
  # here, and not on the Maps page, because a record here is a receipt and not a thing that the
  # owner opens again.
  def prune
    cutoff = MAX_AGE.ago
    records.prune(
      max: MAX_ENTRIES,
      sort_by: ->(record) { record["uploaded_at"].to_s },
      keep: ->(record) { fresh?(record, cutoff) }
    )
  end

  # A record with no date, or with one that Ruby cannot read, is not fresh: it goes away.
  def fresh?(record, cutoff)
    Time.parse(record["uploaded_at"].to_s) >= cutoff
  rescue ArgumentError, TypeError
    false
  end
end
