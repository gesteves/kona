require "digest"

module StandardSiteHelpers
  # The AT Protocol "sortable base32" alphabet, for a TID.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz".freeze

  # Makes the document record key of a Contentful entry: the low 63 bits of the SHA-256 digest of
  # the sys.id, as a TID, because the site.standard.document lexicon needs one.
  # This must stay the same as StandardSite#document_rkey of the api. If it does not, the AT URI here
  # does not agree with the record that the api publishes to the PDS.
  # @param entry_id [String] The Contentful sys.id.
  # @return [String] A TID of 13 characters.
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
