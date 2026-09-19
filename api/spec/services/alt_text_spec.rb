require "rails_helper"

RSpec.describe AltText do
  let(:client) { instance_double(Anthropic::Client) }
  let(:jpeg) { "\xFF\xD8\xFF\xE0jpeg".b }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
    allow(ENV).to receive(:[]).with("ANTHROPIC_ALT_TEXT_MODEL").and_return(nil)
    allow(described_class).to receive(:anthropic_client).and_return(client)
  end

  def message_with(text)
    block = instance_double(Anthropic::Models::TextBlock, type: :text, text: text)
    instance_double(Anthropic::Models::Message, content: [ block ])
  end

  describe ".generate" do
    it "sends the picture as a base64 image block with the prompt, and returns the stripped text" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with("  A dog running on a beach.\n"))
      )

      expect(described_class.generate(image: jpeg)).to eq("A dog running on a beach.")

      expect(client.messages).to have_received(:create).with(
        model: "claude-sonnet-5",
        max_tokens: 512,
        thinking: { type: :disabled },
        system_: described_class::SYSTEM_PROMPT,
        messages: [ { role: "user", content: [
          { type: :image, source: { type: :base64, media_type: :"image/jpeg", data: Base64.strict_encode64(jpeg) } },
          { type: :text, text: described_class::USER_TEXT }
        ] } ],
        request_options: { timeout: 15 }
      )
    end

    it "reads the prompt from the file, and not from the code" do
      expect(described_class::SYSTEM_PROMPT).to eq(Rails.root.join("app/prompts/alt-text.md").read)
      expect(described_class::SYSTEM_PROMPT).to include("<instructions>")
    end

    it "reads the model from its own env var" do
      allow(ENV).to receive(:[]).with("ANTHROPIC_ALT_TEXT_MODEL").and_return("claude-other")
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with("A cat."))
      )

      described_class.generate(image: jpeg)

      expect(client.messages).to have_received(:create).with(hash_including(model: "claude-other"))
    end

    # ⚠️ The prompt asks for less than 1,000 characters, and the field takes 2000 graphemes. An
    # answer past that would make the action refuse the draft.
    it "makes an answer no longer than the alt text limit, in graphemes" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with("👨‍👩‍👧‍👦" * (Bluesky::MAX_ALT_GRAPHEMES + 5)))
      )

      text = described_class.generate(image: jpeg)

      expect(SocialText.graphemes(text)).to eq(Bluesky::MAX_ALT_GRAPHEMES)
    end

    it "returns nil for an empty answer" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with("  "))
      )

      expect(described_class.generate(image: jpeg)).to be_nil
    end

    it "returns nil for a blank picture or when unconfigured, without calling Anthropic" do
      allow(client).to receive(:messages)

      expect(described_class.generate(image: "")).to be_nil

      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      expect(described_class.generate(image: jpeg)).to be_nil

      expect(client).not_to have_received(:messages)
    end

    it "fails soft (nil) on a transport error, and reports it" do
      allow(client).to receive(:messages).and_raise(StandardError.new("boom"))
      allow(ErrorReporter).to receive(:report_upstream)

      expect(described_class.generate(image: jpeg)).to be_nil
      expect(ErrorReporter).to have_received(:report_upstream).with(kind_of(StandardError), hash_including(service: "AltText"))
    end
  end
end
