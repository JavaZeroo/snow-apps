[CmdletBinding()]
# Declared explicitly rather than collected through ValueFromRemainingArguments
# and splatted as an array. That form only ever ran with no arguments, and the
# first call that passed some mis-bound them: package-snow-shot.ps1 saw
# -Architecture "-IncludePortable" and rejected it against its ValidateSet.
# Hashtable splatting of PSBoundParameters keeps each name attached to its own
# value, and an omitted switch stays omitted.
param(
    [ValidateSet("x64", "arm64")]
    [string]$Architecture,
    [switch]$IncludePortable
)
$ErrorActionPreference = "Stop"
& (Join-Path $PSScriptRoot "package-snow-shot.ps1") @PSBoundParameters
exit $LASTEXITCODE
