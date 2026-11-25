require "rails_helper"

RSpec.describe SocialMentions do
  describe ".tokens" do
    it "finds a bare token" do
      expect(described_class.tokens("Great ride with @tony today")).to eq([ "@tony" ])
    end

    it "finds more than one, in order" do
      expect(described_class.tokens("@ana and @ben")).to eq([ "@ana", "@ben" ])
    end

    it "takes a full Mastodon handle as ONE token" do
      # ⚠️ Without the optional second part of the pattern this gives "@me" and then a fragment,
      # and the owner gets two rows for one person.
      expect(described_class.tokens("cc @me@hachyderm.io")).to eq([ "@me@hachyderm.io" ])
    end

    it "finds a token that is a domain" do
      expect(described_class.tokens("cc @tony.bsky.social")).to eq([ "@tony.bsky.social" ])
    end

    it "stops before the punctuation of the sentence" do
      expect(described_class.tokens("thanks @Tony.")).to eq([ "@Tony" ])
      expect(described_class.tokens("that is @Tony's bike")).to eq([ "@Tony" ])
    end

    it "does not read an email address as a token" do
      # The character before the "@" is a word character, thus the boundary group refuses it.
      expect(described_class.tokens("write to me@example.com")).to be_empty
    end

    it "does not read a token inside a URL" do
      # To replace one would break the address.
      expect(described_class.tokens("see https://bsky.app/profile/@tony.bsky.social now")).to be_empty
    end

    it "finds a token beside a URL" do
      expect(described_class.tokens("https://example.com and @tony")).to eq([ "@tony" ])
    end

    it "gives an empty list for a body with no token" do
      expect(described_class.tokens("nothing here")).to be_empty
      expect(described_class.tokens(nil)).to be_empty
    end
  end

  describe ".key" do
    it "removes the @ and folds the case" do
      expect(described_class.key("@Tony")).to eq("tony")
      expect(described_class.key("tony")).to eq("tony")
    end
  end

  describe ".substitute" do
    let(:body) { "Great ride with @tony yesterday." }

    context "when the field holds a handle of that network" do
      it "writes the handle with one @, for each network" do
        expect(described_class.substitute(body, values: { "tony" => "tony.bsky.social" }, network: "bluesky"))
          .to eq("Great ride with @tony.bsky.social yesterday.")
        expect(described_class.substitute(body, values: { "tony" => "tony@hachyderm.io" }, network: "mastodon"))
          .to eq("Great ride with @tony@hachyderm.io yesterday.")
        expect(described_class.substitute(body, values: { "tony" => "tony" }, network: "threads"))
          .to eq("Great ride with @tony yesterday.")
      end

      it "gives the same text for a handle that the owner wrote with an @" do
        with = described_class.substitute(body, values: { "tony" => "@tony.bsky.social" }, network: "bluesky")
        without = described_class.substitute(body, values: { "tony" => "tony.bsky.social" }, network: "bluesky")
        expect(with).to eq(without)
      end
    end

    context "when the field holds plain words" do
      # ⚠️ This is the case of a person with no account at that network. It is a correct answer and
      # not a mistake.
      it "writes the words with no @" do
        expect(described_class.substitute(body, values: { "tony" => "Anthony Edwards" }, network: "mastodon"))
          .to eq("Great ride with Anthony Edwards yesterday.")
      end

      it "removes every @ from the words" do
        # ⚠️ "@Anthony Edwards" would otherwise reach Threads, which reads "@Anthony" and tags a
        # stranger. That is the failure that this class exists to stop.
        expect(described_class.substitute(body, values: { "tony" => "@Anthony Edwards" }, network: "threads"))
          .to eq("Great ride with Anthony Edwards yesterday.")
      end
    end

    context "when the field is empty" do
      it "keeps the words of the token and removes the @" do
        expect(described_class.substitute(body, values: {}, network: "mastodon"))
          .to eq("Great ride with tony yesterday.")
      end

      it "keeps the spelling of the occurrence and not the key of the map" do
        # Thus "@Tony" reads as a name, and the owner writes the token as they write the name.
        expect(described_class.substitute("cc @Tony", values: { "tony" => "" }, network: "threads"))
          .to eq("cc Tony")
      end
    end

    it "replaces each occurrence in ONE pass" do
      # ⚠️ A gsub for each entry of the map would match the "tony" inside the "tony.bsky.social"
      # that it wrote a moment before.
      expect(described_class.substitute("@tony and @tony", values: { "tony" => "tony.bsky.social" },
                                        network: "bluesky"))
        .to eq("@tony.bsky.social and @tony.bsky.social")
    end

    it "matches the key without the case of the token" do
      expect(described_class.substitute("cc @Tony", values: { "tony" => "tony.bsky.social" }, network: "bluesky"))
        .to eq("cc @tony.bsky.social")
    end

    it "leaves a URL and an email address alone" do
      text = "see https://bsky.app/profile/@tony.bsky.social or me@example.com"
      expect(described_class.substitute(text, values: {}, network: "bluesky")).to eq(text)
    end

    it "gives an empty string for no text" do
      expect(described_class.substitute(nil, values: {}, network: "bluesky")).to eq("")
    end
  end

  describe ".handle?" do
    it "knows the shape of each network" do
      expect(described_class.handle?("tony.bsky.social", network: "bluesky")).to be true
      expect(described_class.handle?("tony", network: "bluesky")).to be false

      expect(described_class.handle?("tony@hachyderm.io", network: "mastodon")).to be true
      expect(described_class.handle?("tony", network: "mastodon")).to be false

      expect(described_class.handle?("tony_1", network: "threads")).to be true
      expect(described_class.handle?("Anthony Edwards", network: "threads")).to be false
    end

    it "reads plain words as plain words at each network" do
      described_class::HANDLE_SHAPES.each_key do |network|
        expect(described_class.handle?("Anthony Edwards", network: network)).to be false
      end
    end
  end

  # ⚠️ Ruby reads \w as ASCII by default, exactly as an ordinary JavaScript RegExp does. Thus the
  # boundary of the pattern behaves the same in the two copies, and an accented letter before a
  # token gives a token in both. spec/contracts/social_mentions_contract_spec.rb pins that.
  it "reads the boundary as ASCII, as the browser does" do
    expect(described_class.tokens("café@tony")).to eq([ "@tony" ])
  end

  # ⚠️ A field that holds the handle of another network is otherwise mangled with no message: it is
  # not a domain, thus it becomes plain words and every "@" comes out of the middle of it.
  describe ".mistaken_network" do
    it "names the network that a handle belongs to" do
      expect(described_class.mistaken_network("tony@hachyderm.io", network: "bluesky")).to eq("mastodon")
      expect(described_class.mistaken_network("tony@hachyderm.io", network: "threads")).to eq("mastodon")
      expect(described_class.mistaken_network("tony.bsky.social", network: "mastodon")).to eq("bluesky")
    end

    it "reads a handle of its own network as correct" do
      expect(described_class.mistaken_network("tony.bsky.social", network: "bluesky")).to be_nil
      expect(described_class.mistaken_network("@tony.bsky.social", network: "bluesky")).to be_nil
      expect(described_class.mistaken_network("tony@hachyderm.io", network: "mastodon")).to be_nil
    end

    # ⚠️ These are the examples that DIAGNOSTIC_SHAPES exists for. A plain name is the answer for a
    # person with no account, thus it must pass in every field.
    it "never refuses plain words" do
      described_class::HANDLE_SHAPES.each_key do |network|
        [ "Tony", "Anthony Edwards", "" ].each do |value|
          expect(described_class.mistaken_network(value, network: network)).to be_nil,
            "#{value.inspect} in the #{network} field must not be a mistake."
        end
      end
    end

    # A Threads username takes a period, thus this one is a real username and not a Bluesky handle.
    it "does not refuse a dotted Threads username" do
      expect(described_class.mistaken_network("tony.edwards", network: "threads")).to be_nil
    end
  end
end
