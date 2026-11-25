require "rails_helper"

RSpec.describe AnthropicStructuredOutput do
  let(:host) do
    Module.new do
      extend AnthropicStructuredOutput
      const_set(:DEFAULT_MODEL, "claude-default")
      const_set(:MAX_TOKENS, 200)
      const_set(:TIMEOUT_SECONDS, 7)

      def self.anthropic_model_env = "SPEC_ANTHROPIC_MODEL"
    end
  end

  let(:messages) { double("messages") }
  let(:client) { instance_double(Anthropic::Client, messages: messages) }

  before do
    stub_env("ANTHROPIC_API_KEY" => "key", "SPEC_ANTHROPIC_MODEL" => nil)
    allow(Anthropic::Client).to receive(:new).with(api_key: "key").and_return(client)
  end

  it "is configured with an API key only" do
    expect(host.configured?).to be(true)

    stub_env("ANTHROPIC_API_KEY" => "")
    expect(host.configured?).to be(false)
  end

  it "reads the model from the env var of the caller, and uses the default without one" do
    expect(host.model).to eq("claude-default")

    stub_env("SPEC_ANTHROPIC_MODEL" => "claude-other")
    expect(host.model).to eq("claude-other")
  end

  it "makes one call with the schema, the limits of the caller, and no thinking, and parses the first text block" do
    text_block = double("block", type: :text, text: { line: "A summary." }.to_json)
    allow(messages).to receive(:create).and_return(double("message", content: [ double("tool", type: :tool_use), text_block ], stop_reason: :end_turn))
    schema = { type: "object", properties: { line: { type: "string" } } }

    result = host.structured_call(system: "Be brief.", user: "Summarize.", schema: schema)

    expect(result).to eq(line: "A summary.")
    expect(messages).to have_received(:create).with(
      hash_including(model: "claude-default", max_tokens: 200, thinking: { type: :disabled },
                     system_: "Be brief.", messages: [ { role: "user", content: "Summarize." } ],
                     output_config: { format: { type: :json_schema, schema: schema } },
                     request_options: { timeout: 7, max_retries: 2 })
    )
  end

  it "makes a plain text call with no output config, and gives the first text block stripped" do
    text_block = double("block", type: :text, text: "  A dog.\n")
    allow(messages).to receive(:create).and_return(double("message", content: [ text_block ]))
    content = [ { type: :image, source: { type: :base64, media_type: :"image/jpeg", data: "abc" } } ]

    expect(host.text_call(system: "Describe.", content: content)).to eq("A dog.")

    expect(messages).to have_received(:create).with(
      model: "claude-default", max_tokens: 200, thinking: { type: :disabled },
      system_: "Describe.", messages: [ { role: "user", content: content } ],
      request_options: { timeout: 7, max_retries: 2 }
    )
  end

  it "turns the thinking off with between_tools on Claude Sonnet 5.5, and with disabled on each other model" do
    allow(messages).to receive(:create).and_return(double("message", content: [ double("block", type: :text, text: "A.") ]))

    stub_env("SPEC_ANTHROPIC_MODEL" => "claude-sonnet-5-5")
    host.text_call(system: "s", content: "c")
    expect(messages).to have_received(:create).with(hash_including(thinking: { type: :between_tools }))

    stub_env("SPEC_ANTHROPIC_MODEL" => "claude-haiku-4-5")
    host.text_call(system: "s", content: "c")
    expect(messages).to have_received(:create).with(hash_including(thinking: { type: :disabled }))
  end

  # ⚠️ These models give a 400 for each thinking type that turns the thinking off. For the abuse
  # check, which fails closed, that 400 would hold each contact message in the retries.
  %w[claude-opus-5-5 claude-fable-5-2 claude-mythos-5-2].each do |always_thinking|
    it "refuses #{always_thinking}, which cannot turn its thinking off, and makes no request" do
      allow(messages).to receive(:create)
      stub_env("SPEC_ANTHROPIC_MODEL" => always_thinking)

      expect { host.text_call(system: "s", content: "c") }
        .to raise_error(AnthropicStructuredOutput::UnsupportedModel, /SPEC_ANTHROPIC_MODEL/)
      expect(messages).not_to have_received(:create)
    end
  end

  it "accepts each default model of the callers" do
    [ ContactModeration, ContactSubject, ActivityDescription::Llm, AltText ].each do |caller|
      expect(AnthropicStructuredOutput::ALWAYS_THINKING_MODELS).to all(satisfy { |pattern| !pattern.match?(caller::DEFAULT_MODEL) })
    end
  end

  it "gives nil from a plain text call with no text block" do
    allow(messages).to receive(:create).and_return(double("message", content: [ double("tool", type: :tool_use) ]))

    expect(host.text_call(system: "s", content: "c")).to be_nil
  end

  it "raises Refusal for a declined structured call, and does not parse the answer" do
    allow(messages).to receive(:create).and_return(double("message", content: [], stop_reason: :refusal))

    expect { host.structured_call(system: "s", user: "u", schema: {}) }
      .to raise_error(AnthropicStructuredOutput::Refusal)
  end

  it "keeps one client across the calls" do
    allow(messages).to receive(:create).and_return(double("message", content: [ double("block", type: :text, text: "{}") ], stop_reason: :end_turn))

    2.times { host.structured_call(system: "s", user: "u", schema: {}) }

    expect(Anthropic::Client).to have_received(:new).once
  end
end
