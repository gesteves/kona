module ContextHelpers
  # Determines if the site is currently running on Netlify, based on the presence of a CONTEXT env var.
  # @see https://docs.netlify.com/configure-builds/environment-variables/#build-metadata
  # @return [Boolean] True if the site is on Netlify.
  def is_netlify?
    ENV['CONTEXT'].present?
  end

  # Determines if the site is currently running on Netlify in production.
  # @return [Boolean] True if the site is on prod.
  def is_production?
    ENV['CONTEXT'] == 'production'
  end

  # Determines if the site is currently running on dev using `netlify dev`.
  # @return [Boolean] True if the site is on Netlify's dev environment.
  def is_dev?
    ENV['CONTEXT'] == 'dev'
  end
end
