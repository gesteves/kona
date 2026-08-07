require "rails_helper"

RSpec.describe ContactSubject do
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

  describe ".generate" do
    it "sends the message with structured output and returns the subject" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with(subject: "Question about Alcatraz wetsuit rules"))
      )

      subject = described_class.generate(name: "Jane", message: "Do I need a wetsuit for Escape from Alcatraz?")
      expect(subject).to eq("Question about Alcatraz wetsuit rules")

      expect(client.messages).to have_received(:create).with(
        hash_including(
          max_tokens: 128,
          thinking: { type: :disabled },
          system_: described_class::SYSTEM_PROMPT,
          output_config: hash_including(format: hash_including(type: :json_schema)),
          request_options: { timeout: 15 }
        )
      )
    end

    it "returns nil when the model declines (null subject)" do
      allow(client).to receive(:messages).and_return(
        instance_double(Anthropic::Resources::Messages, create: message_with(subject: nil))
      )

      expect(described_class.generate(name: "Jane", message: "asdfghjkl")).to be_nil
    end

    it "returns nil for a blank message or when unconfigured, without calling Anthropic" do
      allow(client).to receive(:messages)

      expect(described_class.generate(name: "Jane", message: " ")).to be_nil

      allow(ENV).to receive(:[]).with("ANTHROPIC_API_KEY").and_return(nil)
      expect(described_class.generate(name: "Jane", message: "Hello")).to be_nil

      expect(client).not_to have_received(:messages)
    end

    it "fails soft (nil) on a transport error" do
      allow(client).to receive(:messages).and_raise(StandardError.new("boom"))
      allow(ErrorReporter).to receive(:report_upstream)

      expect(described_class.generate(name: "Jane", message: "Hello")).to be_nil
      expect(ErrorReporter).to have_received(:report_upstream)
    end
  end

  describe ".model" do
    it "defaults to claude-sonnet-5 and honors the override" do
      allow(ENV).to receive(:[]).with("ANTHROPIC_CONTACT_SUBJECT_MODEL").and_return(nil)
      expect(described_class.model).to eq("claude-sonnet-5")

      allow(ENV).to receive(:[]).with("ANTHROPIC_CONTACT_SUBJECT_MODEL").and_return("claude-haiku-4-5")
      expect(described_class.model).to eq("claude-haiku-4-5")
    end
  end
end
