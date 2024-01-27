const currentContext = window.currentContext || 'development';

export function isProduction() {
  return currentContext === 'production';
}

export function isDevelopment() {
  return currentContext === 'development';
}

export function isDeployPreview() {
  return currentContext === 'deploy-preview';
}

export function isBranchDeploy() {
  return currentContext === 'branch-deploy';
}
