BeforeAll {
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\mxc.ps1"
}

Describe 'Get-MxcExecutable' -Tag 'Scoop' {
    BeforeAll {
        $originalExecutor = $env:SCOOP_MXC_EXEC
    }

    BeforeEach {
        $env:SCOOP_MXC_EXEC = "$TestDrive\override.exe"
        $userExecutor = "$TestDrive\user\wxc-exec.exe"
        $globalExecutor = "$TestDrive\global\wxc-exec.exe"
        $null = New-Item "$TestDrive\user", "$TestDrive\global" -ItemType Directory -Force
        $null = New-Item $env:SCOOP_MXC_EXEC, $userExecutor, $globalExecutor -ItemType File -Force
        Mock installed { $true }
        Mock currentdir {
            if ($global) { "$TestDrive\global" } else { "$TestDrive\user" }
        }
        Mock Get-Command { [PSCustomObject]@{ Path = "$TestDrive\path\wxc-exec.exe" } } -ParameterFilter {
            $Name -eq 'wxc-exec.exe'
        }
    }

    AfterAll {
        $env:SCOOP_MXC_EXEC = $originalExecutor
    }

    It 'prefers the environment override' {
        Get-MxcExecutable | Should -Be $env:SCOOP_MXC_EXEC
    }

    It 'prefers the user installation over global and PATH' {
        $env:SCOOP_MXC_EXEC = "$TestDrive\missing.exe"
        Get-MxcExecutable | Should -Be $userExecutor
    }

    It 'falls back to the global installation' {
        Remove-Item -LiteralPath $env:SCOOP_MXC_EXEC, $userExecutor
        Get-MxcExecutable | Should -Be $globalExecutor
    }

    It 'falls back to PATH when installed executors are absent' {
        $env:SCOOP_MXC_EXEC = $null
        Remove-Item -LiteralPath $userExecutor, $globalExecutor
        Get-MxcExecutable | Should -Be "$TestDrive\path\wxc-exec.exe"
    }

    It 'does not use an executor from an uninstalled app' {
        $env:SCOOP_MXC_EXEC = $null
        Mock installed { $false }
        Get-MxcExecutable | Should -Be "$TestDrive\path\wxc-exec.exe"
    }

    It 'returns null if no executor is available' {
        $env:SCOOP_MXC_EXEC = $TestDrive
        Mock installed { $false }
        Mock Get-Command {} -ParameterFilter { $Name -eq 'wxc-exec.exe' }
        Get-MxcExecutable | Should -BeNullOrEmpty
    }
}

Describe 'New-MxcConfig' -Tag 'Scoop' {
    BeforeEach {
        Mock installed { $true }
        Mock currentdir { "$TestDrive\apps\$app\current" }
        Mock shimdir { "$TestDrive\shims" }
        Mock abort { throw $msg }
    }

    It 'creates an ordered process container config with network denied and no timeout' {
        $config = New-MxcConfig -App demo -CommandLine '"demo.exe"'
        $config | Should -BeOfType System.Collections.Specialized.OrderedDictionary
        $config.version | Should -Be '1.0.0'
        $config.containerId | Should -Be 'scoop-demo'
        $config.containment | Should -Be 'processcontainer'
        $config.process.commandLine | Should -Be '"demo.exe"'
        $config.process.Contains('timeout') | Should -BeFalse
        $config.filesystem.readonlyPaths | Should -Be @("$TestDrive\apps\demo\current", "$TestDrive\shims", $env:SystemRoot)
        $config.filesystem.readwritePaths | Should -Be @($env:TEMP)
        $config.network.egress.default | Should -Be 'deny'
        $config.ui.disable | Should -BeFalse
        $json = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $json.filesystem.readwritePaths | Should -HaveCount 1
    }

    It 'allows network access, extra writable paths and a positive timeout' {
        $config = New-MxcConfig -App demo -CommandLine demo.exe -AllowNetwork `
            -ReadWritePath @('C:\work', 'D:\data') -TimeoutMs 30000
        $config.network.egress.default | Should -Be 'allow'
        $config.filesystem.readwritePaths | Should -Be @($env:TEMP, 'C:\work', 'D:\data')
        $config.process.timeout | Should -Be 30000
    }

    It 'uses the global app and shims when requested' {
        $null = New-MxcConfig -App demo -CommandLine demo.exe -Global
        Should -Invoke installed -Times 1 -Exactly -ParameterFilter { $app -eq 'demo' -and $global }
        Should -Invoke currentdir -Times 1 -Exactly -ParameterFilter { $app -eq 'demo' -and $global }
        Should -Invoke shimdir -Times 1 -Exactly -ParameterFilter { $global }
    }

    It 'aborts for an app that is not installed' {
        Mock installed { $false }
        { New-MxcConfig -App missing -CommandLine missing.exe } | Should -Throw "*'missing' is not installed*"
    }
}

Describe 'scoop mxc command' -Tag 'Scoop' {
    BeforeAll {
        $savedEnvironment = @{}
        foreach ($name in @('SCOOP', 'SCOOP_GLOBAL', 'SCOOP_MXC_EXEC', 'XDG_CONFIG_HOME')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:SCOOP = "$TestDrive\scoop root"
        $env:SCOOP_GLOBAL = "$TestDrive\global"
        $env:SCOOP_MXC_EXEC = $null
        $env:XDG_CONFIG_HOME = "$TestDrive\config"
        $powershell = (Get-Process -Id $PID).Path
        $scoop = "$PSScriptRoot\..\bin\scoop.ps1"
        $invokeScoop = {
            param($scoop, $arguments)
            & $scoop @arguments
            exit $LASTEXITCODE
        }
        $null = New-Item "$env:SCOOP\shims" -ItemType Directory -Force
        $appPath = "$env:SCOOP\apps\demo\current"
        $globalAppPath = "$env:SCOOP_GLOBAL\apps\demo\current"
        foreach ($path in @($appPath, $globalAppPath)) {
            $null = New-Item "$path\bin" -ItemType Directory -Force
            '{"version":"1.0","bin":[["bin\\demo.exe","alias"],"other.exe"]}' |
                Set-Content "$path\scoop-manifest.json"
            '{"architecture":"64bit"}' | Set-Content "$path\scoop-install.json"
            $null = New-Item "$path\bin\demo.exe" -ItemType File
        }
    }

    AfterAll {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
    }

    It 'prints config and executor command without executing, and removes the temp file' {
        $output = @(& $powershell -NoProfile -Command $invokeScoop -args $scoop, @('mxc', 'demo', '--dry-run'))
        $LASTEXITCODE | Should -Be 0
        $config = $output[0..($output.Count - 2)] -join "`n" | ConvertFrom-Json
        $config.process.commandLine | Should -Be "`"$appPath\bin\demo.exe`""
        $config.network.egress.default | Should -Be 'deny'
        $output[-1] | Should -Match '^& ".*wxc-exec.exe" "([^"]+)"$'
        [regex]::Match($output[-1], '"([^"]+)"$').Groups[1].Value | Should -Not -Exist
    }

    It 'accepts repeated and comma-separated writable paths with network and global options' {
        $arguments = @('mxc', 'demo', '-d', '-n', '-g', '-w', 'C:\one,C:\two', '--rw', 'D:\three', '-w', 'E:\four')
        $output = @(& $powershell -NoProfile -Command $invokeScoop -args $scoop, $arguments)
        $LASTEXITCODE | Should -Be 0
        $config = $output[0..($output.Count - 2)] -join "`n" | ConvertFrom-Json
        $config.network.egress.default | Should -Be 'allow'
        $config.filesystem.readwritePaths | Should -Be @($env:TEMP, 'C:\one', 'C:\two', 'D:\three', 'E:\four')
        $config.filesystem.readonlyPaths[0] | Should -Be $globalAppPath
        $config.filesystem.readonlyPaths[1] | Should -Be "$env:SCOOP_GLOBAL\shims"
        $config.process.commandLine | Should -Be "`"$globalAppPath\bin\demo.exe`""
    }

    It 'preserves explicit command arguments after the separator using Windows quoting' {
        $commandArgs = @('C:\Program Files\demo.exe', '--global', 'two words', '', 'a"b', 'C:\ends with slash\')
        $output = @(& $powershell -NoProfile -Command $invokeScoop -args $scoop, (@('mxc', 'demo', '--dry-run', '--') + $commandArgs))
        $LASTEXITCODE | Should -Be 0
        $config = $output[0..($output.Count - 2)] -join "`n" | ConvertFrom-Json
        $config.process.commandLine | Should -Be '"C:\Program Files\demo.exe" "--global" "two words" "" "a\"b" "C:\ends with slash\\"'
        $config.network.egress.default | Should -Be 'deny'
    }

    It 'aborts with an installation hint when the executor is missing' {
        $env:SCOOP_MXC_EXEC = "$TestDrive\missing.exe"
        # Isolate executor discovery from any MXC installation on the host PATH.
        $originalPath = $env:PATH
        try {
            $env:PATH = "$env:SystemRoot\System32"
            $output = & $powershell -NoProfile -Command $invokeScoop -args $scoop, @('mxc', 'demo')
            $LASTEXITCODE | Should -Be 1
            $output -join "`n" | Should -Match 'scoop install mxc'
        } finally {
            $env:PATH = $originalPath
            $env:SCOOP_MXC_EXEC = $null
        }
    }

    It 'propagates executor exit status and deletes the configuration' {
        $executor = "$TestDrive\executor.cmd"
        @('@echo off', 'copy "%~1" "%~dp0captured.json" >nul', 'echo %~1>"%~dp0config-path.txt"', 'exit /b 23') |
            Set-Content $executor
        $env:SCOOP_MXC_EXEC = $executor
        try {
            & $powershell -NoProfile -Command $invokeScoop -args $scoop, @('mxc', 'demo')
            $LASTEXITCODE | Should -Be 23
            $config = Get-Content "$TestDrive\captured.json" -Raw | ConvertFrom-Json
            $config.containerId | Should -Be 'scoop-demo'
            (Get-Content "$TestDrive\config-path.txt").Trim() | Should -Not -Exist
        } finally {
            $env:SCOOP_MXC_EXEC = $null
        }
    }
}
