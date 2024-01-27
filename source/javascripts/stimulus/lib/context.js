const currentContext = window.currentContext || 'dev';

export function isProduction() {
  return currentContext === 'production';
}

export function isDevelopment() {
  return currentContext === 'dev';
}

export function isDeployPreview() {
  return currentContext === 'deploy-preview';
}

export function isBranchDeploy() {
  return currentContext === 'branch-deploy';
}
