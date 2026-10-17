<# Instance lifetime starts at the cloud creation timestamp, including powered-off time. #>
function Get-InstanceTiming {
  param([string]$DateCreated, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
  $result = [pscustomobject]@{ createdAtUtc=$null; ageSeconds=$null }
  $created = [DateTimeOffset]::MinValue
  $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  if ([DateTimeOffset]::TryParse($DateCreated, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$created) -and $created -le $Now) {
    $result.createdAtUtc = $created.ToUniversalTime().ToString('o')
    $result.ageSeconds = [long][math]::Floor(($Now - $created).TotalSeconds)
  }
  return $result
}

function Format-NodeAge {
  param([long]$Seconds)
  $elapsed = [TimeSpan]::FromSeconds([math]::Max(0, $Seconds))
  $clock = '{0:00}小时 {1:00}分 {2:00}秒' -f $elapsed.Hours, $elapsed.Minutes, $elapsed.Seconds
  if ($elapsed.Days -gt 0) { return "$($elapsed.Days)天 $clock" }
  return $clock
}
