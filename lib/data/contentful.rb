require 'active_support/all'
require_relative 'contentful/client'
require_relative 'contentful/processor'

class Contentful
  def initialize
    @client = ContentfulClient::Client
    processor = ContentfulProcessor.new(@client)
    processor.generate_content!
    @content = processor.content
  end

  # Saves all the content fetched and processed from Contentful as JSON files.
  def save_data
    @content.each do |type, data|
      save_to_file(type, data)
    end
  end

  # Retrieves the location set in the site author's profile.
  # @return [Hash] Location information of the author or an empty hash if not available.
  def location
    @content[:site].dig(:author, :location) || {}
  end

  private

  # Saves data to a JSON file
  # @param type [Symbol] The type of content being saved.
  # @param data [Array, Hash] The data to be saved.
  def save_to_file(type, data)
    file_path = "data/#{type}.json"
    File.open(file_path, 'w') do |file|
      file << data.to_json
    end
  rescue => e
    puts "Failed to save #{type}: #{e.message}"
  end
end
