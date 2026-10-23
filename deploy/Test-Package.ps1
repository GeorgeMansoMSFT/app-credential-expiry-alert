#Requires -Version 7.4
# Offline checks; no tenant or mailbox changes.
$ErrorActionPreference='Stop'
. "$PSScriptRoot/Common.ps1"
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
$path=[IO.Path]::GetTempFileName()
try {
    $config=Get-Content "$PSScriptRoot/config.example.json" -Raw | ConvertFrom-Json -AsHashtable
    $config.tenantId=[guid]::NewGuid().ToString()
    $config.subscriptionId=[guid]::NewGuid().ToString()
    $config | ConvertTo-Json | Set-Content -LiteralPath $path
    $valid=Read-DigestConfig $path
    Assert ($valid.createSharedMailbox -eq $false) 'Existing mailbox must be the default.'
    $parameters=Get-DigestJobParameters $valid
    Assert (!$parameters.ContainsKey('TestRecipient')) 'Scheduled parameters must not redirect owner mail.'
    Assert ($parameters.WarningDays -eq '60' -and $parameters.UrgentDays -eq '30') 'Thresholds were not propagated.'
    $config.createSharedMailbox='false'
    $config | ConvertTo-Json | Set-Content -LiteralPath $path
    $caught=$false; try { Read-DigestConfig $path | Out-Null } catch { $caught=$true }
    Assert $caught 'String mailbox mode should be rejected.'
    $config.createSharedMailbox=$false
    $config.urgentDays=90
    $config | ConvertTo-Json | Set-Content -LiteralPath $path
    $caught=$false; try { Read-DigestConfig $path | Out-Null } catch { $caught=$true }
    Assert $caught 'Invalid threshold ordering should be rejected.'

    $global:digestMailboxExists=$true
    $global:digestMailboxCreated=0
    $global:digestMailboxAddress='app-notifications@contoso.com'
    function Get-EXOMailbox { param($Identity,$ErrorAction) if ($global:digestMailboxExists) { @{PrimarySmtpAddress=$global:digestMailboxAddress} } }
    function New-Mailbox { param([switch]$Shared,$Name,$Alias,$PrimarySmtpAddress) $global:digestMailboxExists=$true; $global:digestMailboxCreated++ }
    Resolve-DigestSender $valid | Out-Null
    Assert ($global:digestMailboxCreated -eq 0) 'Existing-mailbox mode created a mailbox.'
    $global:digestMailboxExists=$false
    $caught=$false; try { Resolve-DigestSender $valid | Out-Null } catch { $caught=$true }
    Assert $caught 'Missing existing mailbox must fail without creating one.'
    Assert ($global:digestMailboxCreated -eq 0) 'Missing existing mailbox caused creation.'
    $valid.createSharedMailbox=$true
    Resolve-DigestSender $valid | Out-Null
    Resolve-DigestSender $valid | Out-Null
    Assert ($global:digestMailboxCreated -eq 1) 'Create mode must create once and reuse on repeat.'
    $global:digestMailboxAddress='different@contoso.com'
    $caught=$false; try { Resolve-DigestSender $valid | Out-Null } catch { $caught=$true }
    Assert $caught 'Mailbox alias mismatch must not silently mis-scope send permissions.'
    $global:digestScopeCreated=0
    $global:digestScopes=@([pscustomobject]@{Name='ExistingScope';RecipientFilter="PrimarySmtpAddress -eq '$($valid.senderMailbox)'";RecipientRoot=$null;ServerFilter='';Exclusive=$false;ScopeRestrictionType='RecipientScope'})
    function Get-ManagementScope { $global:digestScopes }
    function New-ManagementScope {
        param($Name,$RecipientRestrictionFilter)
        $global:digestScopeCreated++
        $scope=[pscustomobject]@{Name=$Name;RecipientFilter=$RecipientRestrictionFilter;RecipientRoot=$null;ServerFilter='';Exclusive=$false;ScopeRestrictionType='RecipientScope'}
        $global:digestScopes+=@($scope)
        $scope
    }
    $scope=Resolve-DigestSendScope $valid
    Assert ($scope.Name -eq 'ExistingScope' -and $global:digestScopeCreated -eq 0) 'Equivalent sender scope must be reused.'
    $valid.senderMailbox='another@contoso.com'
    Resolve-DigestSendScope $valid | Out-Null
    Resolve-DigestSendScope $valid | Out-Null
    Assert ($global:digestScopeCreated -eq 1) 'New sender must create one scope and reuse it.'
    Assert ($global:digestScopes[0].Name -eq 'ExistingScope') 'Existing deployment scope was altered.'
    function Invoke-AzureCli { param($Arguments) @{accessToken='offline-token'} }
    function Invoke-RestMethod {
        param($Uri,$Method,$Authentication,$Token,$ErrorAction,$ContentType,$Body)
        if ($ContentType -eq 'text/powershell') {
            Assert ($Body -is [byte[]]) 'Runbook upload changed bytes into a sequence of numbers.'
            Assert ([Text.Encoding]::UTF8.GetString($Body) -eq '#Requires -Version 7.4') 'Runbook upload bytes changed.'
        } else {
            Assert ($Body -is [string]) 'JSON request was not serialized.'
            Assert (($Body | ConvertFrom-Json).properties.enabled -eq $true) 'JSON request body changed.'
        }
    }
    Invoke-DigestArm -Uri 'https://management.azure.com/offline-test' -Method PUT -Body ([Text.Encoding]::UTF8.GetBytes('#Requires -Version 7.4')) -ContentType 'text/powershell'
    Invoke-DigestArm -Uri 'https://management.azure.com/offline-test' -Method PUT -Body @{properties=@{enabled=$true}}
    'PASS: configuration, mailbox options/reuse, sender scope reuse, binary runbook upload, and JSON request serialization.'
} finally {
    Remove-Item -LiteralPath $path -Force
    Remove-Variable digestMailboxExists,digestMailboxCreated,digestMailboxAddress,digestScopeCreated,digestScopes -Scope Global -ErrorAction SilentlyContinue
}
