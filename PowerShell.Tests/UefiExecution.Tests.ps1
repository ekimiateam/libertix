BeforeAll {
    . "$PSScriptRoot/../Scripts/uefi/Libertix.Uefi.Execution.ps1"
}

Describe "UEFI exception diagnostics" {
    BeforeEach {
        $script:diagnosticLines = [Collections.Generic.List[string]]::new()
        Mock Write-Log {
            param([string]$Message, [string]$Color)
            $script:diagnosticLines.Add($Message)
        }
    }

    It "writes bounded primary-error metadata with correlation and stage" {
        try {
            throw [InvalidOperationException]::new("BootOrder failed")
        } catch {
            $record = $_
        }

        Write-ExceptionDiagnostics `
            -ErrorRecord $record `
            -Kind "Primary" `
            -CorrelationId "0123456789abcdef0123456789abcdef" `
            -Stage "windows.temporary-boot-prepared"

        $script:diagnosticLines[0] | Should -Be "===== PRIMARY ERROR BEGIN ====="
        $script:diagnosticLines | Should -Contain "ErrorKind: Primary"
        $script:diagnosticLines | Should -Contain (
            "CorrelationId: 0123456789abcdef0123456789abcdef"
        )
        $script:diagnosticLines | Should -Contain (
            "Stage: windows.temporary-boot-prepared"
        )
        $script:diagnosticLines | Should -Contain "Message: BootOrder failed"
        $script:diagnosticLines[-1] | Should -Be "===== PRIMARY ERROR END ====="
    }

    It "redacts secret assignments from diagnostic text" {
        ConvertTo-LibertixDiagnosticText `
            -Value "password=visible PASSWORD_HASH:abc123 token:token-value safe=value" |
            Should -Be (
                "password=[REDACTED] PASSWORD_HASH:[REDACTED] " +
                "token:[REDACTED] safe=value"
            )
    }
}
