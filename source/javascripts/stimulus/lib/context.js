const currentContext = window.currentContext || 'dev';

/**
 * Checks if the current context is 'production'.
 * @returns {boolean} True if the current context is 'production', false otherwise.
 */
export function isProduction() {
  return currentContext === 'production';
}

/**
 * Checks if the current context is 'dev'.
 * @returns {boolean} True if the current context is 'dev', false otherwise.
 */
export function isDevelopment() {
  return currentContext === 'dev';
}

/**
 * Checks if the current context is 'deploy-preview'.
 * @returns {boolean} True if the current context is 'deploy-preview', false otherwise.
 */
export function isDeployPreview() {
  return currentContext === 'deploy-preview';
}

/**
 * Checks if the current context is 'branch-deploy'.
 * @returns {boolean} True if the current context is 'branch-deploy', false otherwise.
 */
export function isBranchDeploy() {
  return currentContext === 'branch-deploy';
}

