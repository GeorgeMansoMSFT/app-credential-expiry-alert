#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('All','Azure','Directory','Mailbox')][string]$Stage='All',
    [switch]$DeviceLogin
)
. "$PSScriptRoot/Common.ps1"
$config = Read-DigestConfig $ConfigPath
Connect-DigestAzure $config
$base = Get-DigestBase $config

if ($Stage -in @('All','Azure')) {
    Write-Host 'Deploying Azure resources through an incremental ARM deployment.'
    Invoke-AzureCli @('group','create','--name',$config.resourceGroup,'--location',$config.location) | Out-Null
    $parameters = @{
        location=@{value=$config.location};automationAccountName=@{value=$config.automationAccountName}
        alertEmail=@{value=$config.fallbackRecipient};enableFailureAlert=@{value=$config.enableFailureAlert}
    }
    $file = [IO.Path]::GetTempFileName()
    try {
        @{ '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$parameters } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $file -Encoding utf8
        Invoke-AzureCli @('deployment','group','create','--resource-group',$config.resourceGroup,'--name','credential-digest','--mode','Incremental','--template-file',"$PSScriptRoot/main.json",'--parameters',"@$file") | Out-Null
    } finally { Remove-Item -LiteralPath $file -Force }
    $content = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot '../Send-CredentialDigest.ps1'))
    Invoke-DigestArm -Uri "$base/runbooks/Send-CredentialDigest/draft/content?api-version=2024-10-23" -Method PUT -Body $content -ContentType 'text/powershell' | Out-Null
    Invoke-DigestArm -Uri "$base/runbooks/Send-CredentialDigest/publish?api-version=2024-10-23" -Method POST | Out-Null
}
Write-Host 'Reading the Automation managed identity.'
$account = Invoke-DigestArm -Uri "$($base)?api-version=2024-10-23"
$principalId = $account.identity.principalId
if (!$principalId) { throw 'The Automation account has no system-assigned identity yet. Run the Azure stage first.' }

if ($Stage -in @('All','Directory')) {
    Write-Host 'Signing into Microsoft Graph for directory permission setup.'
    Import-Module Microsoft.Graph.Authentication
    $login = @{ TenantId=$config.tenantId;Scopes=@('Application.Read.All','AppRoleAssignment.ReadWrite.All');ContextScope='Process';NoWelcome=$true }
    if ($DeviceLogin) { $login.UseDeviceAuthentication=$true }
    # Device authentication writes its sign-in code to the output stream.
    Connect-MgGraph @login
    try {
        if ((Get-MgContext).TenantId -ne $config.tenantId) { throw 'Graph signed into the wrong tenant.' }
        $graph = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')" -OutputType PSObject
        # Wait for the new managed identity to replicate into the directory before granting roles.
        for ($attempt=0; $attempt -lt 6; $attempt++) {
            try { Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId" -OutputType PSObject | Out-Null; break }
            catch { if ($attempt -eq 5) { throw }; Start-Sleep -Seconds 10 }
        }
        $assignments = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" -OutputType PSObject
        $mailRole = $graph.appRoles | Where-Object value -EQ 'Mail.Send'
        if (@($assignments.value | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $mailRole.id }).Count) { throw 'Managed identity has unscoped Graph Mail.Send. Remove it before configuring restricted sending.' }
        foreach ($name in @('Application.Read.All','User.ReadBasic.All')) {
            $role = $graph.appRoles | Where-Object { $_.value -eq $name -and $_.allowedMemberTypes -contains 'Application' }
            if (!@($assignments.value | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $role.id }).Count) {
                $body = @{principalId=$principalId;resourceId=$graph.id;appRoleId=$role.id} | ConvertTo-Json
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" -Body $body -ContentType 'application/json' | Out-Null
            }
            Write-Host "Configured Graph read permission: $name"
        }
    } finally { Disconnect-MgGraph | Out-Null }
}

if ($Stage -in @('All','Mailbox')) {
    Write-Host 'Signing into Exchange Online for mailbox permission setup.'
    Import-Module ExchangeOnlineManagement
    if ($DeviceLogin) { Connect-ExchangeOnline -Device -ShowBanner:$false }
    else { Connect-ExchangeOnline -UserPrincipalName $config.exchangeAdminUpn -ShowBanner:$false }
    try {
        $connections=@(Get-ConnectionInformation | Where-Object State -EQ 'Connected')
        if (!$connections.Count -or @($connections | Where-Object { [string]$_.TenantID -ne $config.tenantId }).Count) { throw 'Exchange connection is not exclusively in the configured tenant. Use a fresh PowerShell session.' }
        $mailbox=Resolve-DigestSender $config
        # The Azure managed identity is a service principal, not an app registration we create.
        $exoSp=Get-ServicePrincipal | Where-Object ObjectId -EQ $principalId
        if (!$exoSp) {
            # Resolve the identity client ID using its Azure resource, without another Graph login.
            $identity=Invoke-AzureCli @('ad','sp','show','--id',$principalId)
            New-ServicePrincipal -AppId $identity.appId -ObjectId $principalId -DisplayName $config.automationAccountName | Out-Null
        }
        $scope=Resolve-DigestSendScope $config
        $scopeName=[string]$scope.Name
        Write-Host "Using sender scope: $scopeName"
        $assignmentName="$($config.automationAccountName)-SendMail"
        $assignment=Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
        if (!$assignment) { New-ManagementRoleAssignment -Name $assignmentName -App $principalId -Role 'Application Mail.Send' -CustomResourceScope $scopeName | Out-Null }
        elseif ([string]$assignment.Role -ne 'Application Mail.Send' -or [string]$assignment.RoleAssignee -notin @($principalId,$config.automationAccountName)) {
            throw 'Existing Exchange role assignment differs from the expected identity/role/scope. Inspect it before proceeding.'
        }
        elseif ([string]$assignment.CustomResourceScope -ne $scopeName) {
            Set-ManagementRoleAssignment -Identity $assignmentName -CustomResourceScope $scopeName | Out-Null
        }
        $authorization = @(Test-ServicePrincipalAuthorization -Identity $principalId -Resource $config.senderMailbox)
        $authorization | Format-Table | Out-Host
        if (!(Test-DigestMailSendInScope $authorization)) {
            throw 'Application Mail.Send is not in scope for the sender mailbox yet. Exchange RBAC can take time to apply; rerun the Mailbox stage to recheck.'
        }
    } finally { Disconnect-ExchangeOnline -Confirm:$false }
}
Write-Host 'Setup complete. No new schedule was activated. Run Test-Deployment.ps1 before Enable-Schedule.ps1.'
