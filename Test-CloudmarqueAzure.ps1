function Test-CloudmarqueAzure {

    <#
        .Synopsis
         Runs Pester tests over the Cloudmarque.Azure module, publishing test results.
        
        .Description
         Supports the development lifecycle by running defined tests to check whether
         commands are behaving as expected. Checks that all modules are in place before
         running them.
        
        .Example
         Test-CloudmarqueAzure
    #>

    [CmdletBinding()]
    param(
        [ValidateSet("Auto", "AllUsers", "CurrentUser")]
        [String]
        $Scope = "Auto"
    )

    Process {

        $modules =  @(
            @{ ModuleName = "Pester"; ModuleVersion = "5.0.2" },
            @{ ModuleName = "PSScriptAnalyzer"; ModuleVersion = "1.19.1" }
        );

        .$PSScriptRoot/Cloudmarque.Azure/Install-Dependencies.ps1 -AdditionalModules $modules -Scope $Scope -ImportModules $true -Verbose

        $publishPath = "$PSScriptRoot\publish"
        $testDirectory = "tests"
        $testPath = "$publishPath\$testDirectory"

        New-Item -Path $publishPath -Name $Project -ItemType Directory -Force | Out-Null
        New-Item -Path $testPath -Name $Project -ItemType Directory -Force | Out-Null

        $configuration = [PesterConfiguration]@{
            
            Output = @{
                Verbosity = "Detailed"
            }
            Run = @{
                Path = ".\$testDirectory\*"
            }
            Should = @{
                ErrorAction = "Stop"
            }
            TestResult = @{
                Enabled = $true
                OutputPath = "$testPath\nunit-results.xml"
            }
        }

        Invoke-Pester -Configuration $configuration
    }
}