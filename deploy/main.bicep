targetScope = 'resourceGroup'

param location string = resourceGroup().location
@minLength(6)
@maxLength(50)
param automationAccountName string
param alertEmail string
param enableFailureAlert bool = true

resource account 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
  }
}
resource runtime 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: account
  name: 'PowerShell74'
  location: location
  properties: {
    runtime: { language: 'PowerShell', version: '7.4' }
    defaultPackages: { Az: '12.3.0' }
  }
}
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: account
  name: 'Send-CredentialDigest'
  location: location
  properties: {
    runbookType: 'PowerShell'
    runtimeEnvironment: runtime.name
    logProgress: false
    logVerbose: false
    description: 'Weekly stateless credential expiry digest to application owners.'
  }
}
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (enableFailureAlert) {
  name: '${automationAccountName}-alerts'
  location: 'global'
  properties: {
    groupShortName: 'CredDigest'
    enabled: true
    emailReceivers: [{ name: 'Operations', emailAddress: alertEmail, useCommonAlertSchema: true }]
  }
}
resource failedJobs 'Microsoft.Insights/metricAlerts@2018-03-01' = if (enableFailureAlert) {
  name: '${automationAccountName}-job-failure'
  location: 'global'
  properties: {
    description: 'Credential digest failed, stopped, or suspended.'
    severity: 2
    enabled: true
    scopes: [account.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [{
        name: 'FailedJob'
        criterionType: 'StaticThresholdCriterion'
        metricNamespace: 'Microsoft.Automation/automationAccounts'
        metricName: 'TotalJob'
        timeAggregation: 'Total'
        operator: 'GreaterThan'
        threshold: 0
        dimensions: [
          { name: 'Runbook', operator: 'Include', values: ['Send-CredentialDigest'] }
          { name: 'Status', operator: 'Include', values: ['Failed', 'Stopped', 'Suspended'] }
        ]
      }]
    }
    actions: [{ actionGroupId: actionGroup!.id }]
  }
}
output principalId string = account.identity.principalId
output automationAccountId string = account.id
