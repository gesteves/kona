require "digest"

module StandardSiteHelpers
  # AT Protocol "sortable base32" alphabet, used to encode TIDs.
  # @see https://atproto.com/specs/tid
  TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz".freeze

  # The document record key for a Contentful entry: a TID derived deterministically
  # from the sys.id. The site.standard.document lexicon requires the record key to be a
  # TID — a 13-character base32-sortable identifier — so the sys.id can't be used as the
  # rkey directly. The low 63 bits of the sys.id's SHA-256 digest become the TID's value
  # (the top bit stays 0, as a TID requires).
  # ⚠️ This must stay byte-for-byte identical to api's StandardSite#document_rkey, or the
  # <link rel="site.standard.document"> AT URI here won't match the record published to
  # the PDS by the api.
  # @param entry_id [String] The Contentful sys.id.
  # @return [String] A valid 13-character TID.
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
