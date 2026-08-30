# Finds each @mention in a draft of the Social media page, and writes the words that one network
# needs in place of it.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call. Each method is a class method, thus a caller needs no instance.
#
# ⚠️ The three networks write a mention in three different forms, and the same person has a
# different handle at each one, or no account at all. Thus one body cannot hold a mention that is
# correct everywhere. The owner writes a short token, and the composer asks what that person is
# called at each network. Refer to "The Social media page" in api/CLAUDE.md.
class SocialMentions
  # A mention token in the body of a post.
  #
  # The boundary group is the one of Bluesky::MENTION_PATTERN, and it is what makes an email
  # address not a token: the character before its "@" is a word character.
  #
  # ⚠️ The second "@…" part is optional, and it takes "@me@hachyderm.io" as ONE token. Without it
  # the scan gives "@me" and then a fragment, and the owner gets two rows for one person.
  #
  # Each part ends on an alphanumeric, thus "@Tony." and "@Tony's" stop before the punctuation.
  # ⚠️ **Each pattern here is a STRING first, and a Regexp second.** app/javascript/lib/mentions.js
  # holds the same strings, because the character count in the browser must measure the text that
  # this class makes. An interpolated Ruby Regexp gives a source with `(?-mix:…)` in it, which
  # JavaScript cannot parse, thus a string is the only shape that the two can share.
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

  # The networks whose handle shape is specific enough to NAME a mistake.
  #
  # ⚠️ **Threads is not here, and that is deliberate.** Its shape is letters, digits, a period, and
  # an underscore, thus a plain first name matches it. A check against that shape would refuse
  # "Tony" in the Mastodon field, which is the answer for a person with no account there and the
  # thing that this whole feature exists to permit.
  DIAGNOSTIC_SHAPES = %w[bluesky mastodon].freeze

  class << self
    # Each mention token of a text, in order, with the "@" and the spelling of the owner.
    #
    # ⚠️ A token inside a URL is not a token. "…/profile/@tony.bsky.social" holds one, and to
    # replace it would break the address.
    # @param text [String, nil]
    # @return [Array<String>]
    def tokens(text)
      found = []
      each_token(text.to_s) { |token, _start, _finish| found << token }
      found
    end

    # The key of a token in the mention map.
    #
    # ⚠️ It folds the case. A handle is case-insensitive at the three networks, thus two rows for
    # "@Tony" and "@tony" would be a trap.
    # @param token [String] A token, with or with no "@".
    # @return [String]
    def key(token)
      token.to_s.delete_prefix("@").downcase
    end

    # Writes the text that one network gets.
    #
    # ⚠️ It is ONE left-to-right pass over the offsets of the matches, and never a gsub for each
    # entry of the map. A loop would let a handle that one pass wrote be matched again by a later
    # token: "tony" is a prefix of the "tony.bsky.social" that the pass before it wrote.
    # @param text [String, nil] The body that the owner wrote.
    # @param values [Hash{String => String}] The field of this network, by key. A blank value and a
    #   key that is absent are the same thing.
    # @param network [String] A network key of Admin::SocialController::NETWORKS.
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
    # ⚠️ **A "@" only ever comes back from the handle branch**, which knows the shape. Plain words
    # carry none at all: "@Anthony Edwards" would otherwise reach Threads, which reads "@Anthony"
    # and tags a stranger. That is the failure that this whole class exists to stop.
    #
    # ⚠️ **A blank field gives the spelling of the OCCURRENCE**, and not the key of the map. Thus
    # "@Tony" reads as "Tony", and the owner writes the token as they would write the name.
    # @param token [String] The token, with its "@".
    # @param value [String, nil] The field of this network.
    # @param network [String]
    # @return [String]
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
    # @param network [String]
    # @return [Boolean] True when the value has the shape of a handle of that network.
    def handle?(value, network:)
      shape = HANDLE_SHAPES[network.to_s]
      return false if shape.nil?

      shape.match?(value.to_s)
    end

    # Names the network that a value belongs to, when the field of a different one holds it.
    #
    # ⚠️ It reads a value that is a handle of ITS OWN network as correct and stops, thus a Bluesky
    # handle in the Bluesky field is never a mistake. It also reads plain words as correct: they
    # match no shape here, and they are the answer for a person with no account.
    #
    # This exists because such a value is otherwise mangled with no message: a Mastodon handle in
    # the Bluesky field is not a domain, thus it becomes plain words and .replacement removes the
    # "@" from the middle of it.
    # @param value [String, nil] The field, as the owner wrote it.
    # @param network [String] The network whose field holds it.
    # @return [String, nil] The key of the network that the value belongs to.
    def mistaken_network(value, network:)
      handle = normalize(value)
      return nil if handle.blank? || handle?(handle, network: network)

      (DIAGNOSTIC_SHAPES - [ network.to_s ]).find { |other| handle?(handle, network: other) }
    end

    private

    # Yields each token with its CHARACTER offsets.
    #
    # ⚠️ The offsets are characters, and Bluesky#scan_facets uses BYTES. The two are not the same
    # and they must not be confused: this class does surgery on a Ruby String, and that class
    # writes an offset into a record.
    # @param text [String]
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

    # ⚠️ It uses the URL pattern of Bluesky, which is the one that decides a link facet. Thus a
    # string that becomes a link there is a link here, and one pattern holds that rule.
    # @param text [String]
    # @return [Array<Range>] The character ranges of each bare URL.
    def url_ranges(text)
      ranges = []
      text.scan(Bluesky::URL_PATTERN) do
        start_char, end_char = Regexp.last_match.offset(1)
        ranges << (start_char...end_char)
      end
      ranges
    end
  end
end
