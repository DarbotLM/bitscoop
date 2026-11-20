BeforeDiscovery {
    $manifests = (Get-ChildItem "$PSScriptRoot\..\bucket" -Filter '*.json' -File).FullName
}

Describe 'MXC bucket manifests' -Tag 'Validator' {
    BeforeAll {
        Add-Type -Path "$PSScriptRoot\..\supporting\validator\bin\Scoop.Validator.dll"
        $validator = New-Object Scoop.Validator("$PSScriptRoot\..\schema.json", $true)
    }

    It 'validates <_> against schema.json' -ForEach $manifests {
        $validator.Validate($_) | Should -BeTrue -Because $validator.ErrorsAsString
        $validator.Errors.Count | Should -Be 0
    }

    It 'exposes the MXC executor' {
        $manifest = Get-Content "$PSScriptRoot\..\bucket\mxc.json" -Raw | ConvertFrom-Json
        $manifest.bin | Should -Be 'wxc-exec.exe'
    }
}
