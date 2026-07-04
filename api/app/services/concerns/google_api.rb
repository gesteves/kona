# Shared plumbing for the Google Maps-platform services (Maps, Pollen, Air Quality): the
# one API key they all authenticate with, read in one place.
module GoogleApi
  private

  def google_api_key
    ENV["GOOGLE_API_KEY"]
  end
end
