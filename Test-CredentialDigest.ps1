#Requires -Version 7.4
# Offline integration checks. No Azure or email requests are made.
$ErrorActionPreference = 'Stop'
function Import-Module {}
function Get-MgContext { @{ TenantId='test-tenant' } }
$global:digestTestSent = [System.Collections.Generic.List[object]]::new()
$global:digestTestFailRead = $false
function Invoke-MgGraphRequest {
    param($Uri,$Method,$Body,$ContentType,$ErrorAction,$OutputType)
    if ($global:digestTestFailRead) { throw 'Simulated Graph read failure' }
    if ($Method -eq 'POST') { $global:digestTestSent.Add(($Body | ConvertFrom-Json)); return }
    $now = [datetimeoffset]::UtcNow
    # Round-trip through JSON so endDateTime arrives as a DateTime, as it does from Graph.
    if ($Uri -like '*/applications[?]$select=*') {
        return @{ value=@(@{id='app1';appId='client1';displayName='App <one>';passwordCredentials=@(
            @{keyId='secret60';displayName='Secret';endDateTime=$now.AddDays(60).AddMinutes(-1).ToString('o')},
            @{keyId='secret30';displayName='Secret';endDateTime=$now.AddDays(30).AddMinutes(-1).ToString('o')},
            @{keyId='outside';endDateTime=$now.AddDays(61).ToString('o')}
        );keyCredentials=@(@{keyId='cert';endDateTime=$now.AddDays(10).ToString('o')})}); '@odata.nextLink'='https://graph.microsoft.com/v1.0/applications?page=2' } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    }
    if ($Uri -like '*applications?page=2') {
        return @{value=@(@{id='app2';appId='client2';displayName='Orphan';passwordCredentials=@(
            @{keyId='orphan';endDateTime=$now.AddDays(20).ToString('o')},
            @{keyId='expired';endDateTime=$now.AddDays(-1).ToString('o')}
        );keyCredentials=@()})} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    }
    if ($Uri -like '*/app1/owners/microsoft.graph.user?*') { return @{value=@(@{id='user1';mail='owner@example.com'},@{id='user2';mail=$null})} }
    # app2's only owner is a service principal, so the user-type cast returns nothing.
    if ($Uri -like '*/app2/owners/microsoft.graph.user?*') { return @{value=@()} }
    throw "Unexpected request: $Uri"
}
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$params = @{TenantId='test-tenant';SenderMailbox='sender@example.com';FallbackRecipient='it@example.com';Authentication='ExistingGraphSession'}
$output = @(& "$PSScriptRoot/Send-CredentialDigest.ps1" @params)
$text = $output -join "`n"
Assert ($global:digestTestSent.Count -eq 0) 'Dry run sent mail'
Assert ($text -match 'digests=2') 'Expected one owner digest and one IT digest'
Assert ($text -match 'Upcoming expiry' -and $text -match 'Action required') 'Missing urgency bands'
Assert ($text -match 'secret60' -and $text -match 'secret30' -and $text -match 'cert') 'Missing in-window credentials'
Assert ($text -notmatch 'outside') 'Included out-of-window credential'
Assert ($text -match 'Expired credential' -and $text -match 'No emailable user owner') 'Missing exceptions'
Assert ($text -match 'App &lt;one&gt;') 'HTML was not escaped'
Assert ($text -match 'Action required: application credential expiry digest') 'Urgent digest subject missing'
# Expiry parsing must not depend on the host culture (en-GB reads MM/dd as dd/MM and throws).
$culture = [cultureinfo]::CurrentCulture
try {
    [cultureinfo]::CurrentCulture = 'en-GB'
    $gbText = @(& "$PSScriptRoot/Send-CredentialDigest.ps1" @params) -join "`n"
    Assert ($gbText -match 'credentialsInScope=5') 'Expiry parsing changed under a non-US culture'
} finally { [cultureinfo]::CurrentCulture = $culture }
& "$PSScriptRoot/Send-CredentialDigest.ps1" @params -SendEmail $true -TestRecipient 'test@example.com' | Out-Null
Assert ($global:digestTestSent.Count -eq 2) 'Unexpected sent count'
foreach ($mail in $global:digestTestSent) { Assert ($mail.message.toRecipients[0].emailAddress.address -eq 'test@example.com') 'Test override leaked a recipient' }
$global:digestTestSent.Clear()
& "$PSScriptRoot/Send-CredentialDigest.ps1" @params -ApplicationIds @('client1') -SendEmail $true | Out-Null
Assert ($global:digestTestSent.Count -eq 2) 'App filter should retain the missing-email exception'
Assert (($global:digestTestSent | ConvertTo-Json -Depth 12) -notmatch 'Orphan') 'App filter failed'
$global:digestTestSent.Clear()
$global:digestTestFailRead = $true
$caught = $false
try { & "$PSScriptRoot/Send-CredentialDigest.ps1" @params -SendEmail $true | Out-Null } catch { $caught = $true }
Assert $caught 'Read failure did not fail the job'
Assert ($global:digestTestSent.Count -eq 0) 'Read failure sent partial digests'
'PASS: pagination, 60/30-day bands, certificate and secret coverage, culture-independent expiry parsing, HTML encoding, ownership fallback, expired reporting, app filter, dry run, test override, and read-failure behavior.'

