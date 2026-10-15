$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$sandbox=Join-Path ([IO.Path]::GetTempPath()) ('vultr-portable-test-'+[guid]::NewGuid().ToString('N'))
$project=Join-Path $sandbox 'project'
$source=Join-Path $sandbox 'settings'
New-Item -ItemType Directory -Path $project,$source | Out-Null
foreach($file in @('setup.ps1','nodes.example.json')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $project $file) }

# A clean clone can prepare local templates without credentials or networking.
& (Join-Path $project 'setup.ps1') -InitializeOnly -SkipShortcut
if(-not (Test-Path -LiteralPath (Join-Path $project 'nodes.json'))) { throw 'Missing first-run settings template' }
$exampleBefore=(Get-FileHash -LiteralPath (Join-Path $project 'nodes.json')).Hash
& (Join-Path $project 'setup.ps1') -InitializeOnly -SkipShortcut
if((Get-FileHash -LiteralPath (Join-Path $project 'nodes.json')).Hash -ne $exampleBefore) { throw 'Repeated initialization changed settings' }
$rejected=$false
try { & (Join-Path $project 'setup.ps1') -SkipShortcut } catch {$rejected=$true}
if(-not $rejected) { throw 'Placeholder settings should fail validation' }
Write-Host 'PASS: first-run template initialization is repeatable; unfinished templates are rejected'

# A second clean clone can import exactly two local files.
$secondProject=Join-Path $sandbox 'second-project'
New-Item -ItemType Directory -Path $secondProject | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'setup.ps1') -Destination (Join-Path $secondProject 'setup.ps1')
$fixture=Get-Content -LiteralPath (Join-Path $root 'nodes.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($entry in $fixture.nodes) {
  $entry.domain=$entry.id+'.example.invalid';$entry.startupScriptId='11111111-1111-4111-8111-111111111111'
  $entry.uuid='22222222-2222-4222-8222-222222222222';$entry.publicKey='A'*43;$entry.shortId='0123456789abcdef'
}
[IO.File]::WriteAllText((Join-Path $source 'nodes.json'),($fixture|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $source 'vultr-api.key'),'test-only-not-a-real-key',[Text.UTF8Encoding]::new($false))
function Invoke-RestMethod { throw 'Setup tests must not use the network.' }
& (Join-Path $secondProject 'setup.ps1') -SettingsSource $source -SkipShortcut
& (Join-Path $secondProject 'setup.ps1') -SettingsSource $source -SkipShortcut
foreach($file in @('nodes.json','vultr-api.key')) {
  if((Get-FileHash -LiteralPath (Join-Path $source $file)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $secondProject $file)).Hash) { throw 'Imported settings differ from source' }
}
Write-Host 'PASS: settings pair imports correctly and can be rechecked without overwriting'

[IO.File]::WriteAllText((Join-Path $source 'vultr-api.key'),'different-test-key',[Text.UTF8Encoding]::new($false))
$rejected=$false
try { & (Join-Path $secondProject 'setup.ps1') -SettingsSource $source -SkipShortcut } catch {$rejected=$true}
if(-not $rejected) { throw 'Conflicting settings must not overwrite local settings' }
if([IO.File]::ReadAllText((Join-Path $secondProject 'vultr-api.key')) -ne 'test-only-not-a-real-key') { throw 'Local key was overwritten' }
$fixture.nodes[1].domain=$fixture.nodes[0].domain
[IO.File]::WriteAllText((Join-Path $secondProject 'nodes.json'),($fixture|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$rejected=$false
try { & (Join-Path $secondProject 'setup.ps1') -SkipShortcut } catch {$rejected=$true}
if(-not $rejected) { throw 'Duplicate domains should fail validation' }
Write-Host 'PASS: conflicting imports and duplicate domains are rejected'
Write-Host 'All setup tests passed. Only disposable local fixtures were used.'
