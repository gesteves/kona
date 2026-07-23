module ContextHelpers
  # The deploy context this build runs in — "production" for the real public site,
  # anything else for previews/branches. DEPLOY_CONTEXT is the platform-neutral variable
  # (set explicitly in CI env config); CONTEXT is Netlify's build metadata, kept as a
  # fallback until the Cloudflare migration retires it.
  # @return [String, nil] The current deploy context.
  def deploy_context
    ENV['DEPLOY_CONTEXT'].presence || ENV['CONTEXT'].presence
  end

  # Determines if the site is currently running on Netlify, based on the presence of a CONTEXT env var.
  # @see https://docs.netlify.com/configure-builds/environment-variables/#build-metadata
  # @return [Boolean] True if the site is on Netlify.
  def netlify?
    ENV['CONTEXT'].present?
  end

  # Determines if this build is the real public site (as opposed to a preview or local dev).
  # @return [Boolean] True if this is a production build.
  def production?
    deploy_context == 'production'
  end
end
