# Finds each @mention in a draft of the Social media page, and writes the words that one network
# needs in place of it.
#
# It is not an ApplicationService, because it makes no network call. Each method is a class method.
#
# ⚠️ The three networks write a mention in three different forms, and one person has a different
# handle at each one, or no account. Thus the owner writes a short token, and the composer asks
# what that person is called at each network. Refer to "The Social media page" in api/CLAUDE.md.
class SocialMentions
  # A mention token in the body of a post.
  #
  # The boundary group is the one of Bluesky::MENTION_PATTERN. Thus an email address is not a
  # token: the character before its "@" is a word character.
  #
  # ⚠️ The second "@…" part is optional, and it takes "@me@hachyderm.io" as ONE token. Without it
  # the scan gives "@me" and then a fragment, and the owner gets two rows for one person.
  #
  # Each part ends on an alphanumeric, thus "@Tony." and "@Tony's" stop before the punctuation.
  #
  # ⚠️ Each pattern here is a String first, and a Regexp second.
  # app/javascript/lib/social_mentions.js holds the same strings, because the character count in
  # the browser must measure the text that this class makes. JavaScript cannot parse the source of
  # an interpolated Ruby Regexp, which holds `(?-mix:…)`.
  # spec/contracts/social_mentions_contract_spec.rb compares them.
  TOKEN_SOURCE = "(?:^|[$|\\W])(@[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?(?:@[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?)?)".freeze
  # The shape of one DNS label, from Bluesky::MENTION_PATTERN.
  LABEL_SOURCE = "[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?".freeze
  # A domain, which is the form of a Bluesky handle.
  DOMAIN_SOURCE = "(?:#{LABEL_SOURCE}\\.)+[a-zA-Z](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?".freeze

  TOKEN_PATTERN = Regexp.new(TOKEN_SOURCE)

  # The shape of a handle at each network. ⚠️ These SELECT and they never refuse: a value that
  # matches none of them is plain words, which is a correct answer for a person with no account
  # there. Refer to .replacement.
  HANDLE_SHAPES = {
    "bluesky"  => /\A#{DOMAIN_SOURCE}\z/,
    "mastodon" => /\A[a-zA-Z0-9_](?:[a-zA-Z0-9_.-]*[a-zA-Z0-9_])?@#{DOMAIN_SOURCE}\z/,
    "threads"  => /\A[a-zA-Z0-9._]{1,30}\z/
  }.freeze

  # The networks whose handle shape is specific enough to name a mistake.
  #
  # ⚠️ Threads is not here, on purpose. A plain first name matches its shape. Thus a check against
  # that shape would refuse "Tony" in the Mastodon field, which is the answer for a person with no
  # account there.
  DIAGNOSTIC_SHAPES = %w[bluesky mastodon].freeze

  class << self
    # Each mention token of a text, in order, with the "@" and the spelling of the owner.
    #
    # ⚠️ A token inside a URL is not a token. "…/profile/@tony.bsky.social" holds one, and to
    # replace it would break the address.
    # @param text [String, nil]
    def tokens(text)
      found = []
      each_token(text.to_s) { |token, _start, _finish| found << token }
      found
    end

    # The key of a token in the mention map.
    #
    # ⚠️ It folds the case. A handle is case-insensitive at the three networks, thus "@Tony" and
    # "@tony" must share one row.
    # @param token [String] A token, with or with no "@".
    def key(token)
      token.to_s.delete_prefix("@").downcase
    end

    # Writes the text that one network gets.
    #
    # ⚠️ It is ONE left-to-right pass over the offsets of the matches, and never a gsub for each
    # entry of the map. A later gsub would match a handle that an earlier one wrote: "tony" is a
    # prefix of "tony.bsky.social".
    # @param text [String, nil] The body that the owner wrote.
    # @param values [Hash{String => String}] The field of this network, by key. A blank value and a
    #   key that is absent are the same thing.
    # @param network [String] A network key of SocialDraft::NETWORKS.
    # @return [String]
    def substitute(text, values:, network:)
      text = text.to_s
      out = +""
      last = 0

      each_token(text) do |token, start_char, end_char|
        out << text[last...start_char]
        out << replacement(token, values[key(token)], network: network)
        last = end_char
      end

      out << text[last..].to_s
    end

    # The words that go in place of one token.
    #
    # ⚠️ Only the handle branch returns a "@", because it knows the shape. Plain words carry none:
    # "@Anthony Edwards" would reach Threads, which reads "@Anthony" and tags a stranger.
    #
    # ⚠️ A blank field gives the spelling of the occurrence, and not the key of the map. Thus
    # "@Tony" reads as "Tony", and the owner writes the token as they would write the name.
    # @param token [String] The token, with its "@".
    # @param value [String, nil] The field of this network.
    def replacement(token, value, network:)
      value = value.to_s.strip
      return token.delete_prefix("@") if value.blank?

      handle = normalize(value)
      return "@#{handle}" if handle?(handle, network: network)

      value.delete("@")
    end

    # @param value [String, nil]
    # @return [String] The value with no leading "@" and no space at either end. A handle that the
    #   owner writes with or with no "@" gives the same text.
    def normalize(value)
      value.to_s.strip.sub(/\A@+/, "")
    end

    # @param value [String, nil] A value that .normalize made.
    # @return [Boolean] True when the value has the shape of a handle of that network.
    def handle?(value, network:)
      shape = HANDLE_SHAPES[network.to_s]
      return false if shape.nil?

      shape.match?(value.to_s)
    end

    # Names the network that a value belongs to, when the field of a different one holds it.
    # Without this, a Mastodon handle in the Bluesky field becomes plain words with no message, and
    # .replacement removes the "@" from the middle of it.
    #
    # ⚠️ A handle of its own network is correct, thus a Bluesky handle in the Bluesky field is never
    # a mistake. Plain words are also correct: they match no shape here, and they are the answer for
    # a person with no account.
    # @param value [String, nil] The field, as the owner wrote it.
    # @param network [String] The network whose field holds it.
    # @return [String, nil] The key of the network that the value belongs to.
    def mistaken_network(value, network:)
      handle = normalize(value)
      return nil if handle.blank? || handle?(handle, network: network)

      (DIAGNOSTIC_SHAPES - [ network.to_s ]).find { |other| handle?(handle, network: other) }
    end

    private

    # Yields each token with its character offsets.
    #
    # ⚠️ The offsets are characters, and Bluesky#scan_facets uses bytes. This class edits a Ruby
    # String, and that class writes an offset into a record.
    # @yieldparam token [String]
    # @yieldparam start_char [Integer]
    # @yieldparam end_char [Integer]
    def each_token(text)
      skip = url_ranges(text)

      text.scan(TOKEN_PATTERN) do
        match = Regexp.last_match
        start_char, end_char = match.offset(1)
        next if skip.any? { |range| range.cover?(start_char) }

        yield match[1], start_char, end_char
      end
    end

    # @return [Array<Range>] The character ranges of each bare URL.
    def url_ranges(text)
      SocialText.url_ranges(text)
    end
  end
end
