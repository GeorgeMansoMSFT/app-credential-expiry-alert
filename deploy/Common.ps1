#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-DigestConfig([string]$Path) {
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in @('tenantId','subscriptionId')) {
        $guid = [guid]::Empty
        if (![guid]::TryParse($c[$key], [ref]$guid) -or $guid -eq [guid]::Empty) { throw "Set a valid $key in the configuration." }
    }
    foreach ($key in @('resourceGroup','location','automationAccountName','exchangeAdminUpn','senderMailbox','sharedMailboxName','fallbackRecipient','testRecipient','scheduleTimeZone','scheduleDay')) {
        if (![string]$c[$key]) { throw "Missing configuration: $key" }
    }
    foreach ($key in @('senderMailbox','fallbackRecipient','testRecipient','exchangeAdminUpn')) {
        $mail = [System.Net.Mail.MailAddress]::new($c[$key])
        if ($mail.Address -ne $c[$key] -or $c[$key] -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw "Use a plain email address for $key." }
    }
    foreach ($key in @('createSharedMailbox','enableFailureAlert')) {
        if ($c[$key] -isnot [bool]) { throw "$key must be a JSON boolean." }
    }
    if ($c.automationAccountName -notmatch '^[a-zA-Z][a-zA-Z0-9-]{5,49}$') { throw 'Automation account name: 6-50 letters, digits, or hyphens; start with a letter.' }
    foreach ($key in @('warningDays','urgentDays','scheduleHour')) { if ($c[$key] -isnot [long] -and $c[$key] -isnot [int]) { throw "$key must be an integer." } }
    if ($c.warningDays -lt 1 -or $c.warningDays -gt 3650 -or $c.urgentDays -lt 1 -or $c.urgentDays -gt $c.warningDays) { throw 'Require 1 <= urgentDays <= warningDays <= 3650.' }
    if ($c.scheduleHour -lt 0 -or $c.scheduleHour -gt 23) { throw 'scheduleHour must be 0-23.' }
    if ($c.scheduleDay -notin [enum]::GetNames([DayOfWeek])) { throw 'scheduleDay must be a full English weekday name.' }
    [TimeZoneInfo]::FindSystemTimeZoneById($c.scheduleTimeZone) | Out-Null
    return $c
}
function Invoke-AzureCli([string[]]$Arguments) {
    $output = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0]) $($Arguments[1])." }
    if ($output) { return ($output -join "`n" | ConvertFrom-Json -AsHashtable) }
}
function Connect-DigestAzure($Config) {
    $account = Invoke-AzureCli @('account','show')
    if ($account.tenantId -ne $Config.tenantId -or $account.id -ne $Config.subscriptionId) {
        throw 'Azure CLI context differs from config. Run az login --tenant TENANT and az account set --subscription SUBSCRIPTION.'
    }
}
function Invoke-DigestArm {
    param([string]$Uri, [string]$Method='GET', $Body, [string]$ContentType='application/json')
    if (!$Uri.StartsWith('https://management.azure.com/')) { throw 'Unexpected Azure management URL.' }
    $token = Invoke-AzureCli @('account','get-access-token','--resource','https://management.azure.com/')
    $request = @{Uri=$Uri;Method=$Method;Authentication='Bearer';Token=(ConvertTo-SecureString $token.accessToken -AsPlainText -Force);ErrorAction='Stop'}
    if ($null -ne $Body) {
        $request.ContentType = $ContentType
        # Assign directly: an if-expression would enumerate byte[] into object[].
        if ($Body -is [byte[]]) { $request.Body = $Body }
        else { $request.Body = $Body | ConvertTo-Json -Depth 20 }
    }
    Invoke-RestMethod @request
}
function Get-DigestBase($Config) {
    "https://management.azure.com/subscriptions/$($Config.subscriptionId)/resourceGroups/$($Config.resourceGroup)/providers/Microsoft.Automation/automationAccounts/$($Config.automationAccountName)"
}
function Get-DigestJobParameters($Config) {
    @{
        TenantId=$Config.tenantId;SenderMailbox=$Config.senderMailbox;FallbackRecipient=$Config.fallbackRecipient
        WarningDays=[string]$Config.warningDays;UrgentDays=[string]$Config.urgentDays
    }
}
function Resolve-DigestSender($Config) {
    $mailbox=Get-EXOMailbox -Identity $Config.senderMailbox -ErrorAction SilentlyContinue
    if (!$mailbox) {
        if (!$Config.createSharedMailbox) { throw 'Existing sender mailbox was not found. Supply an existing mailbox or set createSharedMailbox=true.' }
        New-Mailbox -Shared -Name $Config.sharedMailboxName -Alias $Config.senderMailbox.Split('@')[0] -PrimarySmtpAddress $Config.senderMailbox | Out-Null
        for ($attempt=0; $attempt -lt 6; $attempt++) {
            $mailbox=Get-EXOMailbox -Identity $Config.senderMailbox -ErrorAction SilentlyContinue
            if ($mailbox) { break }; Start-Sleep -Seconds 10
        }
        if (!$mailbox) { throw 'Mailbox is still provisioning. Rerun the Mailbox stage later.' }
    }
    if ([string]$mailbox.PrimarySmtpAddress -ne $Config.senderMailbox) { throw 'Set senderMailbox to the mailbox primary SMTP address, then rerun.' }
    return $mailbox
}
function Test-DigestMailSendInScope($Authorization) {
    # Exchange may return InScope as the string "True"/"False"; any nonempty string is truthy,
    # so compare its text. [string]$true is also "True", so a real boolean passes the same test.
    [bool]@($Authorization | Where-Object { [string]$_.RoleName -eq 'Application Mail.Send' -and [string]$_.InScope -eq 'True' }).Count
}
function Resolve-DigestSendScope($Config) {
    $filter="PrimarySmtpAddress -eq '$($Config.senderMailbox.Replace("'","''"))'"
    $scope=Get-ManagementScope | Where-Object {
        ($_.RecipientFilter -eq $filter -or $_.RecipientFilter -eq "($filter)") -and
        !$_.RecipientRoot -and !$_.ServerFilter -and !$_.Exclusive -and $_.ScopeRestrictionType -eq 'RecipientScope'
    } | Select-Object -First 1
    if ($scope) { return $scope }
    # Exchange rejects duplicate scope definitions, even with different names.
    # Reuse equivalent scopes; never change another deployment's scope filter.
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Config.senderMailbox.ToLowerInvariant()))).Substring(0,12)
    New-ManagementScope -Name "CredentialDigest-$hash" -RecipientRestrictionFilter $filter
}
