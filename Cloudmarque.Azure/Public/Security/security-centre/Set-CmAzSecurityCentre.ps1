function Set-CmAzSecurityCentre {

    <#
        .Synopsis
         Deploys Security Centre settings for the current subscription.

        .Description
         Completes the following:
            * Sets security centre to standard pricing for the current subscription.
            * Adds uk and nhs official policies.
            * Turns on auto provisioning and sends logging to a specified workspace.
            * Turns on threat detection integrations MCAS and WDATP.
            * Sets email addresses and phone numbers to be notified for when compromised resources are detected.

        .Parameter SettingsFile
         Settings file path for which to into a setting object.

        .Parameter SettingsObject
         Settings object

        .Component
         Security

        .Example
         Set-CmAzSecurityCentre -SettingsFile "c:/directory/settingsFile.yml"

        .Example
         Set-CmAzSecurityCentre -SettingsObject $settings
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
    param(
        [parameter(Mandatory = $true, ParameterSetName = "Settings File")]
        [string]$SettingsFile,
        [parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
        [object]$SettingsObject
    )

	$ErrorActionPreference = "Stop"

    try {

        if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Security Centre")) {

            if ($SettingsFile -and !$SettingsObject) {
                $SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
            }
            elseif (!$SettingsFile -and !$SettingsObject) {
                Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
            }

            if (!$SettingsObject.Location) {
                Write-Error "Please provide a valid location." -Category InvalidArgument -CategoryTargetName "Location"
            }

            Write-Verbose "Checking security contacts are valid..."
            if (!$SettingsObject.SecurityContacts -or !$SettingsObject.SecurityContacts.Primary.Email -or !$SettingsObject.SecurityContacts.Primary.Phone) {
                Write-Error "Please provide at primary email address and phone number." -Category InvalidArgument -CategoryTargetName "SecurityContacts"
            }

            if(!$SettingsObject.EnableUkNHS -eq $null) {
                $SettingsObject.EnableUkNHS = $false
            }

			$workspace = Get-CmAzService -Service $SettingsObject.service.dependencies.workspace -ThrowIfUnavailable -ThrowIfMultiple

            Write-Verbose "Deploying security centre settings..."
            New-AzDeployment `
                -AssignUkNhs $SettingsObject.EnableUkNhs `
                -Location $SettingsObject.Location `
                -TemplateFile "$PSScriptRoot/Set-CmAzSecurityCentre.json" `
                -InitiativeLocation $SettingsObject.Location `
                -SecurityContacts $SettingsObject.SecurityContacts `
                -Workspace $workspace

            Write-Verbose "Finished!"
        }
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($PSItem);
    }
}