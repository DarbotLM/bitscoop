function Get-MxcExecutable {
    if ($env:SCOOP_MXC_EXEC -and (Test-Path -LiteralPath $env:SCOOP_MXC_EXEC -PathType Leaf)) {
        return (Convert-Path -LiteralPath $env:SCOOP_MXC_EXEC)
    }

    foreach ($global in @($false, $true)) {
        if (installed 'mxc' $global) {
            $path = "$(currentdir 'mxc' $global)\wxc-exec.exe"
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                return $path
            }
        }
    }

    $command = Get-Command 'wxc-exec.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Path }
    return $null
}

function New-MxcConfig {
    param(
        [Parameter(Mandatory = $true)]
        [String] $App,
        [Parameter(Mandatory = $true)]
        [String] $CommandLine,
        [Switch] $Global,
        [Switch] $AllowNetwork,
        [String[]] $ReadWritePath,
        [ValidateRange(0, [int]::MaxValue)]
        [Int] $TimeoutMs = 0
    )

    if (!(installed $App $Global)) {
        abort "'$App' is not installed$(if ($Global) { ' globally' })."
    }

    $config = [ordered]@{
        version = '1.0.0'
        containerId = "scoop-$App"
        containment = 'processcontainer'
        process = [ordered]@{ commandLine = $CommandLine }
        filesystem = [ordered]@{
            readonlyPaths = @((currentdir $App $Global), (shimdir $Global), $env:SystemRoot)
            readwritePaths = @($env:TEMP) + @($ReadWritePath | Where-Object { $_ })
        }
        network = @{ egress = @{ default = $(if ($AllowNetwork) { 'allow' } else { 'deny' }) } }
        ui = @{ disable = $false }
    }
    if ($TimeoutMs -gt 0) { $config.process.timeout = $TimeoutMs }
    return $config
}
