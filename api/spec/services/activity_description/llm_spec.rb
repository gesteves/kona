require "rails_helper"

RSpec.describe ActivityDescription::Llm do
  let(:client) { instance_double(Anthropic::Client) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return("key")
    allow(described_class).to receive(:anthropic_client).and_return(client)
  end

  def message_with(json)
    block = instance_double(Anthropic::Models::TextBlock, type: :text, text: json.to_json)
    instance_double(Anthropic::Models::Message, content: [block])
  end

  describe ".planned_summary" do
    it "sends the prompt with structured output and returns the summary" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with(planned_summary: "2 hours of sweet spot"))
      )

      expect(described_class.planned_summary("2x20 @ 90% FTP")).to eq("2 hours of sweet spot")

      expect(client.messages).to have_received(:create).with(
        hash_including(
          max_tokens: 512,
          thinking: { type: :disabled },
          system_: described_class::PLANNED_SUMMARY_PROMPT,
          output_config: hash_including(format: hash_including(type: :json_schema)),
          request_options: { timeout: 30 }
        )
      )
    end

    it "returns nil when the model declines (null summary)" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with(planned_summary: nil))
      )

      expect(described_class.planned_summary("sparse")).to be_nil
    end

    it "returns nil for blank input or when unconfigured" do
      expect(described_class.planned_summary(" ")).to be_nil

      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      expect(described_class.planned_summary("2x20")).to be_nil
    end
  end

  describe ".weather_sentence" do
    it "returns the emoji and sentence" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with(weather_emoji: "🌤️", weather_sentence: "Mild and sunny"))
      )

      expect(described_class.weather_sentence("18°C, sunny")).to eq(emoji: "🌤️", sentence: "Mild and sunny")
    end

    it "returns nil when the model declines either field" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with(weather_emoji: nil, weather_sentence: "x"))
      )

      expect(described_class.weather_sentence("sparse")).to be_nil
    end
  end

  describe ".model" do
    it "defaults to claude-sonnet-5 and honors the override" do
      allow(ENV).to receive(:[]).with("ANTHROPIC_DESCRIPTION_MODEL").and_return(nil)
      expect(described_class.model).to eq("claude-sonnet-5")

      allow(ENV).to receive(:[]).with("ANTHROPIC_DESCRIPTION_MODEL").and_return("claude-opus-4-8")
      expect(described_class.model).to eq("claude-opus-4-8")
    end
  end
end
