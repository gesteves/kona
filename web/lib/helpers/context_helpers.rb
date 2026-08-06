module ContextHelpers
  # @return [String, nil] The deploy context, set in the build env.
  def deploy_context
    ENV['DEPLOY_CONTEXT'].presence
  end

  # @return [Boolean] Whether this build is the real public site.
  def production?
    deploy_context == 'production'
  end
end
