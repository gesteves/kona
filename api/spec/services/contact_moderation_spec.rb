require "rails_helper"

RSpec.describe ContactModeration do
  let(:client) { instance_double(Anthropic::Client) }
  let(:messages) { instance_double(Anthropic::Resources::Messages) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
    allow(ENV).to receive(:[]).with("ANTHROPIC_CONTACT_MODERATION_MODEL").and_return(nil)
    allow(described_class).to receive(:anthropic_client).and_return(client)
    allow(client).to receive(:messages).and_return(messages)
  end

  def answer(abusive)
    block = instance_double(Anthropic::Models::TextBlock, type: :text, text: { abusive: abusive }.to_json)
    allow(messages).to receive(:create)
      .and_return(instance_double(Anthropic::Models::Message, content: [ block ], stop_reason: :end_turn))
  end

  describe ".abusive?" do
    it "sends the name and the message with structured output and no thinking" do
      answer(false)

      expect(described_class.abusive?(name: "Jane", message: "Loved the Alcatraz report!")).to be(false)
      expect(messages).to have_received(:create).with(
        hash_including(
          model: "claude-sonnet-5-5",
          max_tokens: 64,
          thinking: { type: :between_tools },
          system_: described_class::SYSTEM_PROMPT,
          messages: [ { role: "user", content: "From: Jane\n\nMessage:\nLoved the Alcatraz report!" } ],
          output_config: { format: { type: :json_schema, schema: described_class::SCHEMA } },
          request_options: { timeout: 15 }
        )
      )
    end

    it "is true when the model marks the message as abusive" do
      answer(true)

      expect(described_class.abusive?(name: "Troll", message: "You're an idiot.")).to be(true)
    end

    # A message that starts a safety classifier must not go to the inbox with no check.
    it "is true when the model refuses the message" do
      allow(messages).to receive(:create)
        .and_return(instance_double(Anthropic::Models::Message, content: [], stop_reason: :refusal))

      expect(described_class.abusive?(name: "Troll", message: "…")).to be(true)
    end

    it "is false for a blank message or with no configuration, and calls nothing" do
      allow(messages).to receive(:create)

      expect(described_class.abusive?(name: "Jane", message: " ")).to be(false)

      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      expect(described_class.abusive?(name: "Jane", message: "Hello")).to be(false)

      expect(messages).not_to have_received(:create)
    end

    # ⚠️ It fails closed, thus the intake job runs again and no message skips the check.
    it "raises on each other failure" do
      allow(messages).to receive(:create).and_raise(StandardError.new("boom"))

      expect { described_class.abusive?(name: "Jane", message: "Hello") }.to raise_error(StandardError, "boom")
    end
  end

  describe ".model" do
    it "defaults to claude-sonnet-5-5 and honors the override" do
      expect(described_class.model).to eq("claude-sonnet-5-5")

      allow(ENV).to receive(:[]).with("ANTHROPIC_CONTACT_MODERATION_MODEL").and_return("claude-opus-5-5")
      expect(described_class.model).to eq("claude-opus-5-5")
    end
  end
end
