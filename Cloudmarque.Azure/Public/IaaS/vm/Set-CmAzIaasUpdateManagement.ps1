function Set-CmAzIaasUpdateManagement {

	<#
		.Synopsis
		 Sets core monitor automation settings.

		.Description
		 Sets scehdules in the core automation account for updating vms.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 Set-CmAzCoreMonitorLoggingAutomation -SettingsFile "c:/directory/settingsFile.yml"

		.Example
		 Set-CmAzCoreMonitorLoggingAutomation -SettingsObject $settings
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[string]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[object]$SettingsObject
	)

	$ErrorActionPreference = "Stop"

	if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Core Logging Automation")) {

		if ($SettingsFile -and !$SettingsObject) {
			$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
		}
		elseif (!$SettingsFile -and !$SettingsObject) {
			Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
		}

		Write-Verbose "Fetching schedule settings.."
		$scheduleTypeSettingsObject = Get-CmAzSettingsFile -Path "$PSScriptRoot/scheduletypes.yml"

		if (!$scheduleTypeSettingsObject) {
			Write-Error "No valid schedule settings." -Category ObjectNotFound -CategoryTargetName "scheduleTypeSettingsObject"
		}

		$schedules = [System.Collections.ArrayList]@()

		foreach ($scheduleSetting in  $SettingsObject.WindowsUpdateSchedules) {

			$updateTypes = $scheduleTypeSettingsObject.updateGroups[$scheduleSetting.UpdateGroup]

			if (!$updateTypes) {
				Write-Error "Update type not recognised." -Category InvalidArgument -CategoryTargetName "updateTypes"
			}

			$frequency = $scheduleTypeSettingsObject.updateFrequencies[$scheduleSetting.Frequency]

			if (!$frequency) {
				Write-Error "Frequency not recognised." -Category InvalidArgument -CategoryTargetName "frequency"
			}

			$schedule = @{
				"updateTypes" = $updateTypes;
				"tagValue"    = "";

				# Create schedule details in a schema that matches the arm template
				"details"     = @{
					"expiryTime" = $scheduleSetting.ExpiryTime;
					"frequency"  = $frequency;
					"interval"   = 1;
					"name"       = Get-CmAzResourceName -Resource "AutomationSchedule" -Architecture "Core" -Region $SettingsObject.Location -Name $scheduleSetting.Name;
					"startTime"  = $scheduleSetting.StartTime;
					"timeZone"   = "Europe/London";
					"advancedSchedule" = @{
						"weekDays" 	= @();
						"monthDays" = @();
						"monthlyOccurrences" = @()
					};
				}
			}

			$updateGroupTag = $scheduleSetting.UpdateGroup
			$frequencyTag = $scheduleSetting.Frequency

			Write-Verbose "Update schedule set to $($frequency).."
			if ($frequency -eq $scheduleTypeSettingsObject.updateFrequencies.weekly) {

				$dayOfWeek = (get-date $scheduleSetting.StartTime).DayOfWeek
				$frequencyTag = $dayOfWeek
				$schedule.details.advancedSchedule.weekDays += $dayOfWeek
			}
			elseif ($frequency -eq $scheduleTypeSettingsObject.updateFrequencies.monthly) {

				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
				$schedule.details.advancedSchedule.monthDays += (get-date $scheduleSetting.StartTime).Day
			}

			$schedule.tagValue = "$($updateGroupTag)-$($frequencyTag)"

			$schedules.Add($schedule)
		}

		$automationAccount = Get-CmAzService -Service $SettingsObject.service.dependencies.automation -ThrowIfUnavailable -ThrowIfMultiple
		$workspace = Get-CmAzService -Service $SettingsObject.service.dependencies.workspace -ThrowIfUnavailable -ThrowIfMultiple

		Write-Verbose "Deploying Core Logging Automation..."
		New-AzResourceGroupDeployment `
			-ResourceGroupName $automationAccount.resourceGroupName `
			-TemplateFile "$PSScriptRoot/Set-CmAzIaasUpdateManagement.json" `
			-AutomationAccountName $automationAccount.name `
			-UpdateSchedules $schedules `
			-Force

		New-AzResourceGroupDeployment `
			-ResourceGroupName $workspace.resourceGroupName `
			-TemplateFile "$PSScriptRoot/Set-CmAzIaasUpdateManagement.LinkedServices.json" `
			-AutomationAccount $automationAccount `
			-WorkspaceName $workspace.name `
			-Force
	}
}