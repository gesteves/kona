# The reads and the writes of a library of job records: one Redis hash of JSON records (refer to
# JsonHashStore), each with an "id", a "status", and an "uploaded_at". UploadLibrary and
# TrackLibrary both keep their records this way, and an admin page reads each one again while a
# job runs.
#
# The class that includes this supplies `REDIS_KEY`. It keeps its own `stage` and its own `prune`,
# because the fields of a record and the retention rule are different in each library.
module JsonRecordLibrary
  # All the records, the newest first.
  # @return [Array<Hash>]
  def all
    records.read_all.values.sort_by { |record| record["uploaded_at"].to_s }.reverse
  end

  # @return [Hash, nil]
  def find(id)
    records.read(id)
  end

  # id => status, for the poll endpoint of the page. It is not the full records, on purpose,
  # because the page gets this each few seconds while a job runs.
  # @return [Hash{String => String}]
  def statuses
    all.to_h { |record| [ record["id"], record["status"].to_s ] }
  end

  # Changes one record in place.
  # @param changes [Hash] The changes to put on top of the stored record.
  # @return [Hash, nil] The new record, or nil if the record is gone.
  def update(id, changes)
    record = find(id)
    return nil if record.nil?

    write(id, record.merge(changes.transform_keys(&:to_s)))
  end

  # @return [Boolean] True if the code removed a record.
  def delete(id)
    records.delete(id).positive?
  end

  def count
    records.count
  end

  private

  def records
    @records ||= JsonHashStore.new(self.class::REDIS_KEY)
  end

  def write(id, record)
    records.write(id, record)
  end
end
