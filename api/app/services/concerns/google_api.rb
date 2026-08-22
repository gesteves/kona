# The shared code of the services on the Google Maps platform: Maps, Pollen, and Air Quality. They
# all use one API key, and this file reads it in one place.
module GoogleApi
  private

  def google_api_key
    ENV["GOOGLE_API_KEY"]
  end
end
