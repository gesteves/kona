require "active_support/all"
require "httparty"

# The robots.txt rules that block the AI scrapers, from Known Agents.
module KnownAgents
  # The endpoint that makes the rules, and the agent types that we block. "AI Data Scraper" is the
  # family that takes the text of a page to train a model. The list of the agents in that family
  # changes, thus the build gets the rules again each time.
  API_URL = "https://api.knownagents.com/robots-txts".freeze
  AGENT_TYPES = [ "AI Data Scraper", "Undocumented AI Agent" ].freeze

  # Gets the rules and writes them to data/known_agents.json. source/robots.txt.erb renders them
  # between the rule for each other crawler and the Sitemap line.
  #
  # With no access token, and on a non-2xx answer, it writes nothing and gives no message, and the
  # rules are then absent from robots.txt.
  def self.import
    token = ENV["KNOWN_AGENTS_ACCESS_TOKEN"].to_s
    return if token.blank?

    response = HTTParty.post(
      API_URL,
      headers: {
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json"
      },
      body: { agent_types: AGENT_TYPES, disallow: "/" }.to_json,
      timeout: 15
    )
    return unless response.success? && response.body.present?

    rules = response.body.strip
    return if rules.blank?

    File.write("data/known_agents.json", { robots_txt: rules }.to_json)
  end
end
