$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$files=@(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File)
foreach($file in $files) {
  $tokens=$null; $parseErrors=$null
  [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
  if($parseErrors.Count) { throw ("PowerShell syntax errors in {0}: {1}" -f $file.Name,($parseErrors.Message -join '; ')) }
  $bytes=[IO.File]::ReadAllBytes($file.FullName)
  if($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {
    throw "Save $($file.Name) as UTF-8 with BOM for Windows PowerShell 5.1."
  }
}
Write-Host "PASS: parsed $($files.Count) PowerShell scripts and checked UTF-8 BOM encoding"
$tracked=@(git -C $root ls-files)
if($LASTEXITCODE -ne 0) { throw 'Cannot inspect tracked files.' }
$forbidden=@($tracked | Where-Object {
  $_ -match '(^|/)(nodes\.json|vultr-api\.key|startup-script\.id|lax-bootstrap\.sh)$' -or
  $_ -match '\.(key|pem|log|zip|exe)$' -or
  $_ -match '^(客户端配置|备份[^/]*|backups|private-settings)/'
})
if($forbidden.Count) { throw ('Private/generated files must not be tracked: '+($forbidden -join ', ')) }
Write-Host 'PASS: no forbidden private/generated files are tracked'
