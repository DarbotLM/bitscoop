# Usage: scoop mxc <app> [options] [-- <command> [args]]
# Summary: Run an installed app inside an MXC process container
# Help: Network access is denied by default.
#
# Options:
#   -n, --allow-network  Allow outbound network access
#   -w, --rw <path>      Allow writes to a path (repeatable or comma separated)
#   -g, --global         Run a globally installed app
#   -d, --dry-run        Print config JSON and executor command without running
#
# Without a command after '--', use the first executable in the app's bin.
# Quote '--' in PowerShell to pass the command separator literally.

param($App)

. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\json.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\versions.ps1"
. "$PSScriptRoot\..\lib\mxc.ps1"

if (!$App) { my_usage; exit 1 }

$commandArgs = @()
$optionArgs = @($Args)
$separator = [Array]::IndexOf($optionArgs, '--')
if ($separator -ge 0) {
    $commandArgs = @($optionArgs | Select-Object -Skip ($separator + 1))
    $optionArgs = @($optionArgs | Select-Object -First $separator)
}
$opt, $remaining, $err = getopt $optionArgs 'nw:gd' @('allow-network', 'rw=', 'global', 'dry-run')
if ($err) { abort "scoop mxc: $err" }
if ($remaining.Count) { abort "scoop mxc: Put the command after '--'." }

# getopt retains only the last value of a repeated option.
$readWritePaths = @()
for ($i = 0; $i -lt $optionArgs.Count; $i++) {
    if ($optionArgs[$i] -eq '--rw' -or $optionArgs[$i] -match '^-[ngd]*w$') {
        $readWritePaths += $optionArgs[++$i] -split ','
    }
}

$global = $opt.g -or $opt.global
$dryRun = $opt.d -or $opt.'dry-run'
if (!(installed $App $global)) { abort "'$App' is not installed$(if ($global) { ' globally' })." }

if (!$commandArgs.Count) {
    $appPath = currentdir $App $global
    $manifest = installed_manifest $App (Split-Path $appPath -Leaf) $global
    $install = install_info $App (Split-Path $appPath -Leaf) $global
    $bins = @(arch_specific 'bin' $manifest $install.architecture)
    if (!$bins.Count -or !$bins[0]) { abort "'$App' has no bin executable; specify a command after '--'." }
    $executable = Join-Path $appPath (@($bins[0])[0])
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) {
        abort "Could not find executable '$(friendly_path $executable)'."
    }
    $commandArgs = @($executable)
}

# Quote each Windows argv element, including embedded quotes and trailing backslashes.
$commandLine = ($commandArgs | ForEach-Object {
    '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}) -join ' '
$config = New-MxcConfig -App $App -CommandLine $commandLine -Global:$global `
    -AllowNetwork:($opt.n -or $opt.'allow-network') -ReadWritePath $readWritePaths
$wxc = Get-MxcExecutable
if (!$wxc) {
    if (!$dryRun) { abort "MXC executor not found. Run 'scoop install mxc'." }
    $wxc = 'wxc-exec.exe'
}

$configFile = [System.IO.Path]::GetTempFileName()
try {
    $json = $config | ConvertTo-Json -Depth 10
    if ($dryRun) {
        Write-Output $json
        Write-Output "& `"$wxc`" `"$configFile`""
        return
    }
    $json | Out-UTF8File $configFile -ErrorAction Stop
    & $wxc $configFile
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $configFile -Force
}
exit $exitCode
