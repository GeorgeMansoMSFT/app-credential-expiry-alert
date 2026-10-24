#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$SenderMailbox,
    [Parameter(Mandatory)][string]$FallbackRecipient,
    [string]$TestRecipient,
    [string[]]$ApplicationIds = @(),
    [ValidateRange(1,3650)][int]$WarningDays = 60,
    [ValidateRange(1,3650)][int]$UrgentDays = 30,
    [ValidateSet('true','false')][string]$SendEmail = 'false',
    [ValidateSet('ManagedIdentity','ExistingGraphSession')][string]$Authentication = 'ManagedIdentity'
)
$ErrorActionPreference = 'Stop'
$sendEnabled = [System.Convert]::ToBoolean($SendEmail)
if ($UrgentDays -gt $WarningDays) { throw 'UrgentDays must not exceed WarningDays.' }
foreach ($address in @($SenderMailbox,$FallbackRecipient,$TestRecipient)) {
    if ($address -and ([System.Net.Mail.MailAddress]::new($address).Address -ne $address)) { throw 'Use plain email addresses.' }
}

if ($Authentication -eq 'ManagedIdentity') {
    Import-Module Az.Accounts
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -Tenant $TenantId | Out-Null
} else {
    Import-Module Microsoft.Graph.Authentication
    $context = Get-MgContext
    if (!$context -or $context.TenantId -ne $TenantId) { throw 'Connect-MgGraph to the specified tenant first.' }
}

function Invoke-Graph {
    param([string]$Uri, [string]$Method = 'GET', $Body)
    # Only retry reads: retrying an ambiguous sendMail response can duplicate mail.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $request = @{ Uri=$Uri; Method=$Method; ErrorAction='Stop' }
            if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 12 -Compress; $request.ContentType = 'application/json' }
            if ($Authentication -eq 'ExistingGraphSession') {
                return Invoke-MgGraphRequest @request -OutputType PSObject
            }
            $token = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com/'
            $request.Authentication = 'Bearer'
            $request.Token = if ($token.Token -is [securestring]) { $token.Token } else { ConvertTo-SecureString $token.Token -AsPlainText -Force }
            return Invoke-RestMethod @request
        } catch {
            $response = $_.Exception.PSObject.Properties['Response']
            $status = if ($response -and $response.Value) { [int]$response.Value.StatusCode } else { 0 }
            # A read that got no HTTP response (timeout, DNS failure, socket reset) is transient too.
            $transport = $false
            for ($inner = $_.Exception; $inner; $inner = $inner.InnerException) {
                if ($inner -is [System.Net.Http.HttpRequestException] -or $inner -is [System.Threading.Tasks.TaskCanceledException] -or $inner -is [System.IO.IOException]) { $transport = $true }
            }
            $retryable = $status -in @(429,500,502,503,504) -or (!$status -and $transport)
            if ($Method -ne 'GET' -or !$retryable -or $attempt -eq 4) { throw }
            $delay = [int][math]::Pow(2, $attempt + 1)
            $retryAfter = if ($status) { $response.Value.Headers.RetryAfter }
            if ($retryAfter.Delta) { $delay = [math]::Max($delay, [int][math]::Ceiling($retryAfter.Delta.TotalSeconds)) }
            elseif ($retryAfter.Date) { $delay = [math]::Max($delay, [int][math]::Ceiling(($retryAfter.Date - [datetimeoffset]::UtcNow).TotalSeconds)) }
            Start-Sleep -Seconds $delay
        }
    }
}
function Get-GraphCollection([string]$Uri) {
    while ($Uri) {
        $page = Invoke-Graph -Uri $Uri
        foreach ($item in $page.value) { $item }
        $Uri = $page.'@odata.nextLink'
        if ($Uri -and !$Uri.StartsWith('https://graph.microsoft.com/v1.0/')) { throw 'Unexpected pagination URL.' }
    }
}
function Encode($Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }

$now = [datetimeoffset]::UtcNow
$apps = @(Get-GraphCollection 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,passwordCredentials,keyCredentials&$top=999')
if ($ApplicationIds.Count) { $apps = @($apps | Where-Object appId -In $ApplicationIds) }
$digests = @{}
$exceptions = [System.Collections.Generic.List[object]]::new()
$credentialCount = 0
foreach ($app in $apps) {
    $rows = @(
        foreach ($kind in @('passwordCredentials','keyCredentials')) {
            foreach ($credential in $app.$kind) {
                if (!$credential.endDateTime) { continue }
                # Cast, not Parse(): JSON conversion already yields a UTC DateTime, and Parse() would
                # round-trip it through a culture-formatted string with no offset (wrong zone, or a throw).
                $expiry = [datetimeoffset]$credential.endDateTime
                if ($expiry -gt $now.AddDays($WarningDays)) { continue }
                [pscustomobject]@{
                    App=$app.displayName; AppId=$app.appId; ObjectId=$app.id
                    Type=$(if ($kind -eq 'passwordCredentials') {'Secret'} else {'Certificate'})
                    Credential=$credential.displayName; KeyId=$credential.keyId
                    Expiry=$expiry.ToUniversalTime().ToString('u'); Days=[int][math]::Ceiling(($expiry-$now).TotalDays)
                    Status=$(if ($expiry -le $now) {'Expired'} elseif ($expiry -le $now.AddDays($UrgentDays)) {'Action required'} else {'Upcoming expiry'})
                }
            }
        }
    )
    if (!$rows.Count) { continue }
    $credentialCount += $rows.Count
    # The type cast returns user owners only; service principal owners cannot receive mail.
    $owners = @(Get-GraphCollection "https://graph.microsoft.com/v1.0/applications/$($app.id)/owners/microsoft.graph.user?`$select=id,mail")
    $addresses = @(
        foreach ($owner in $owners) {
            $mail = $owner.mail
            if (!$mail) { $exceptions.Add([pscustomobject]@{ App=$app.displayName; Issue="Owner $($owner.id) has no mail address" }) ; continue }
            try { $parsed = [System.Net.Mail.MailAddress]::new($mail) } catch { $parsed = $null }
            if (!$parsed -or $parsed.Address -ne $mail) { $exceptions.Add([pscustomobject]@{ App=$app.displayName; Issue="Owner $($owner.id) has an invalid mail address" }); continue }
            $mail.ToLowerInvariant()
        }
    ) | Sort-Object -Unique
    $active = @($rows | Where-Object Status -NE 'Expired')
    foreach ($address in $addresses) {
        if (!$active.Count) { continue }
        if (!$digests.ContainsKey($address)) { $digests[$address] = [System.Collections.Generic.List[object]]::new() }
        foreach ($row in $active) { $digests[$address].Add($row) }
    }
    foreach ($row in $rows) {
        if ($row.Status -eq 'Expired' -or !$addresses.Count) {
            $exceptions.Add([pscustomobject]@{ App=$app.displayName; Issue=$(if ($row.Status -eq 'Expired') {'Expired credential'} else {'No emailable user owner'}); Credential=$row })
        }
    }
}

$messages = [System.Collections.Generic.List[object]]::new()
foreach ($recipient in ($digests.Keys | Sort-Object)) {
    $tableRows = foreach ($row in ($digests[$recipient] | Sort-Object Days,App)) {
        $link = "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$($row.AppId)/isMSAApp~/false"
        '<tr><td><a href="{0}">{1}</a><br>{2}</td><td>{3}<br>{4}<br>{5}</td><td>{6}</td><td>{7}</td><td>{8}</td></tr>' -f (Encode $link),(Encode $row.App),(Encode $row.AppId),(Encode $row.Type),(Encode $row.Credential),(Encode $row.KeyId),(Encode $row.Expiry),$row.Days,(Encode $row.Status)
    }
    $html = '<h2>Application credential expiry digest</h2><p>Generated {0} UTC. Weekly reminders continue while credentials remain in scope.</p><table border="1" cellpadding="6"><tr><th>Application / client ID</th><th>Credential / ID</th><th>Expiry (UTC)</th><th>Days left</th><th>Status</th></tr>{1}</table><p>Review each credential. If still needed, replace it and update the consuming workload. Validate the replacement before removing the old credential. A replacement credential does not prove the workload has been updated.</p>' -f $now.ToString('yyyy-MM-dd HH:mm'),($tableRows -join '')
    $subject = if (@($digests[$recipient] | Where-Object Status -EQ 'Action required').Count) { 'Action required: application credential expiry digest' } else { 'Upcoming: application credential expiry digest' }
    $messages.Add([pscustomobject]@{ To=$recipient; Subject=$subject; Html=$html })
}
if ($exceptions.Count) {
    $detail = $exceptions | ConvertTo-Json -Depth 8
    $messages.Add([pscustomobject]@{ To=$FallbackRecipient; Subject='Application credential expiry: IT exceptions'; Html="<h2>IT exception digest</h2><pre>$(Encode $detail)</pre>" })
}
$failures = 0
foreach ($message in $messages) {
    $actualRecipient = if ($TestRecipient) { $TestRecipient } else { $message.To }
    $html = if ($TestRecipient) { "<p>TEST - intended recipient: $(Encode $message.To)</p>$($message.Html)" } else { $message.Html }
    if (!$sendEnabled) {
        [pscustomobject]@{ Mode='DryRun'; Recipient=$actualRecipient; IntendedRecipient=$message.To; Subject=$message.Subject; Html=$html } | ConvertTo-Json -Depth 5
        continue
    }
    try {
        $body = @{ message=@{ subject=$message.Subject; body=@{contentType='HTML';content=$html}; toRecipients=@(@{emailAddress=@{address=$actualRecipient}}) }; saveToSentItems=$true }
        Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($SenderMailbox))/sendMail" -Method POST -Body $body | Out-Null
        Write-Output "Mail accepted by Graph for $actualRecipient (intended: $($message.To))."
    } catch { $failures++; Write-Warning "Mail submission failed for $actualRecipient. $($_.Exception.Message)" }
}
Write-Output "Summary: apps=$($apps.Count); credentialsInScope=$credentialCount; digests=$($messages.Count); exceptions=$($exceptions.Count); sendFailures=$failures; sendEmail=$SendEmail"
if ($failures) { throw "$failures mail submission(s) failed. Review job output before retrying; a retry can duplicate successfully submitted digests." }
