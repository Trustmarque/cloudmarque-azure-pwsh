function Sync-CloudmarqueAzure {

    <#
        .Synopsis
         Removes the current in-session Cloudmarque Azure module and reloads it.

        .Description
         Supports the development lifecycle by removing all existing versions of
         Cloudmarque Azure and reloading them. This is great for development
         scenarios where changes to a module or package may have been made and
         need to be reflected in a current PowerShell session for testing.

        .Example
         Sync-CloudmarqueAzure -Uninstall $True
    #>

    [CmdletBinding()]
    param(
        [Bool]
        $Uninstall = $false
    )
    Process {

        $module = "Cloudmarque.Azure";

        # If we're explicitly asked to uninstall, nuke the installed module
        if ($uninstall -And (Get-InstalledModule -Name $module)) {
            Write-Host "Uninstalling module $module..."
            Uninstall-Module $module -Force
        }

        # Usually we're just removing the module from the current session
        if (Get-Module -Name $module) {
            Write-Host "Removing module $module..."
            Remove-Module $module
        }

        # Reimport and show details
        Import-Module "$PSScriptRoot\$module\$module.psm1"
        Get-Module $module
    }
}