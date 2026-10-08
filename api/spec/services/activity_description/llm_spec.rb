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
    instance_double(Anthropic::Models::Message, content: [ block ])
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
          thinking: { type: :between_tools },
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

  describe ".weather_conditions" do
    let(:messages) { instance_double(Anthropic::Resources::Messages) }

    before { allow(client).to receive(:messages).and_return(messages) }

    def answer(phrase)
      allow(messages).to receive(:create).and_return(message_with(notes: "Cloudy once, Drizzle once.", phrase: phrase))
    end

    it "sends the list of conditions alone, and reads the phrase and not the notes" do
      answer("Cloudy, then drizzle")

      expect(described_class.weather_conditions([ "Cloudy", "Drizzle" ])).to eq("Cloudy, then drizzle")
      expect(messages).to have_received(:create).with(
        hash_including(
          system_: described_class::WEATHER_CONDITIONS_PROMPT,
          messages: [ { role: "user", content: "Cloudy, Drizzle" } ],
          output_config: { format: { type: :json_schema, schema: described_class::WEATHER_CONDITIONS_SCHEMA } }
        )
      )
    end

    it "removes quotation marks and a period at the end" do
      answer('"Cloudy, then drizzle."')

      expect(described_class.weather_conditions([ "Cloudy", "Drizzle" ])).to eq("Cloudy, then drizzle")
    end

    # ⚠️ Code writes each number of the line.
    it "discards a phrase with a digit, a line break, the separator, or too many characters" do
      [ "Cloudy, then 20 minutes of drizzle", "Cloudy\nthen drizzle", "Cloudy · drizzle", "Cloudy, #{'then cloudy again, ' * 4}" ].each do |text|
        answer(text)
        expect(described_class.weather_conditions([ "Cloudy", "Drizzle" ])).to be_nil
      end
    end

    # The Strava run and the Whoop run must write the same words.
    it "keeps the phrase of a list in Redis, and asks one time" do
      answer("Cloudy, then drizzle")

      2.times { expect(described_class.weather_conditions([ "Cloudy", "Drizzle" ])).to eq("Cloudy, then drizzle") }
      expect(messages).to have_received(:create).once
    end

    it "returns nil with no list or when unconfigured" do
      expect(described_class.weather_conditions(nil)).to be_nil

      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      expect(described_class.weather_conditions([ "Cloudy", "Drizzle" ])).to be_nil
    end
  end

  describe ".model" do
    it "defaults to claude-sonnet-5-5 and honors the override" do
      allow(ENV).to receive(:[]).with("ANTHROPIC_DESCRIPTION_MODEL").and_return(nil)
      expect(described_class.model).to eq("claude-sonnet-5-5")

      allow(ENV).to receive(:[]).with("ANTHROPIC_DESCRIPTION_MODEL").and_return("claude-opus-4-8")
      expect(described_class.model).to eq("claude-opus-4-8")
    end
  end
end
