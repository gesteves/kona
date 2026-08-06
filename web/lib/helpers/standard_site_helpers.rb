require "digest"

module StandardSiteHelpers
  # AT Protocol "sortable base32" alphabet, used to encode TIDs.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz".freeze

  # Derives a Contentful entry's document record key: the low 63 bits of the sys.id's SHA-256
  # digest, encoded as a TID, since the site.standard.document lexicon requires one.
  # Must stay identical to the api's StandardSite#document_rkey, or the AT URI emitted here
  # won't match the record the api publishes to the PDS.
  # @param entry_id [String] The Contentful sys.id.
  # @return [String] A 13-character TID.
  def document_rkey(entry_id)
    value = Digest::SHA256.hexdigest(entry_id.to_s).to_i(16) & ((1 << 63) - 1)
    encoded = +""
    while value.positive?
      encoded = TID_ALPHABET[value % 32] + encoded
      value /= 32
    end
    encoded.rjust(13, TID_ALPHABET[0])
  end
end
