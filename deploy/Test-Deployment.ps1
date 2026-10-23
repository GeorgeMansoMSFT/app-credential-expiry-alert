#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [ValidateSet('DryRun','TestInbox','Owners')][string]$Mode='DryRun',
    [string[]]$ApplicationIds=@(),
    [guid]$JobId=[guid]::Empty
)
. "$PSScriptRoot/Common.ps1"
$config=Read-DigestConfig $ConfigPath
Connect-DigestAzure $config
$base=Get-DigestBase $config
if ($JobId -eq [guid]::Empty) {
    $parameters=Get-DigestJobParameters $config
    $parameters.SendEmail=if ($Mode -eq 'DryRun') { 'false' } else { 'true' }
    if ($Mode -ne 'Owners') { $parameters.TestRecipient=$config.testRecipient }
    if ($ApplicationIds.Count) { $parameters.ApplicationIds=ConvertTo-Json -InputObject @($ApplicationIds) -Compress }
    $JobId=[guid]::NewGuid()
    Invoke-DigestArm -Uri "$base/jobs/$($JobId)?api-version=2024-10-23" -Method PUT -Body @{properties=@{runbook=@{name='Send-CredentialDigest'};parameters=$parameters}} | Out-Null
    Write-Host "Started $Mode job: $JobId"
}
$job=Invoke-DigestArm -Uri "$base/jobs/$($JobId)?api-version=2024-10-23"
Write-Host "Status: $($job.properties.status)"
if ($job.properties.exception) { Write-Host $job.properties.exception }
$uri="$base/jobs/$JobId/streams?api-version=2024-10-23"
while ($uri) {
    $page=Invoke-DigestArm -Uri $uri
    foreach ($stream in $page.value) {
        $detail=Invoke-DigestArm -Uri "https://management.azure.com$($stream.id)?api-version=2024-10-23"
        Write-Output "[$($detail.properties.streamType)] $($detail.properties.streamText)"
    }
    $uri=if ($page.PSObject.Properties.Name -contains 'nextLink') { $page.nextLink } else { $null }
}
if ($job.properties.status -in @('Failed','Stopped','Suspended')) { throw "Job $JobId did not complete successfully." }
if ($job.properties.status -ne 'Completed') { Write-Host "Check again: ./deploy/Test-Deployment.ps1 -ConfigPath '$ConfigPath' -JobId $JobId" }
