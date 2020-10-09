function Set-CmAzCoreAutomationDeleteResource {

	<#
		.Synopsis
		 Enables feature to delete resources on a given date.

		.Description
		 Completes the following:
			* Uploads a runbook on automation account which delete resources on date given in "cm-delete" tag.
			* Creates Job schedule

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 Set-CmAzCoreAutomationDeleteResource -SettingsFile "cm-delete.yml"

		.Example
		 Set-CmAzCoreAutomationDeleteResource -SettingsObject $settings
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[String]$SettingsFile,

		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[Object]$SettingsObject
	)

	$ErrorActionPreference = "Stop"

	try {

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Enable delete resource of tagged date feature using automation account")) {

			# Initializing settings file values
			if ($SettingsFile -and !$SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (!$SettingsFile -and !$SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			$automationService = Get-CmAzService -Service $SettingsObject.service.dependencies.automation -Region $SettingsObject.location -ThrowIfUnavailable -ThrowIfMultiple
			$cmDeleteRunbook = "Delete-TaggedResource.Runbook"

			# Check Modules and install them if not available
			$dataFile = (Import-PowerShellDataFile "./Cloudmarque.Azure/Cloudmarque.Azure.psd1") 
			
			$modules = $dataFile.requiredModules

			$modules += @{
				"ModuleName" = $dataFile.rootModule.TrimEnd(".psm1");
				"RequiredVersion" = $dataFile.moduleVersion
			}

			Foreach ($module in $modules) {
				$moduleStatus = Get-AzAutomationModule -AutomationAccountName $automationService.name -ResourceGroupName $automationService.resourceGroupName | Where-Object {$_.name -match $module}

				if(!$moduleStatus) {
					Write-Output "$module not Found. I will be imported in automation account shared resources."
					New-AzAutomationModule -AutomationAccountName $automationService.Name -ResourceGroupName $automationService.resourceGroupName -Name $module -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/$module"
				}
			}

			# Import runbook to automation account
			Write-Verbose "Automation Account found."
			$exists = Get-AzAutomationRunbook -Name $cmDeleteRunbook -ResourceGroupName $automationService.resourceGroupName -AutomationAccountName $automationService.name -ErrorAction SilentlyContinue

			if ($exists) {
				Write-Verbose "Removing existing Delete-TaggedResource.Runbook"
				Remove-AzAutomationRunbook -Name $cmDeleteRunbook -ResourceGroupName $automationService.resourceGroupName -AutomationAccountName $automationService.name -Force
			}

			Write-Verbose "Importing Runbook into the automation account."
			Import-AzAutomationRunbook -Name $cmDeleteRunbook -Path "$PSScriptRoot/../../../../Runbooks/Delete-TaggedResource.Runbook.ps1" `
				-ResourceGroupName $automationService.resourceGroupName -AutomationAccountName $automationService.name `
				-Type PowerShell -Published

			# Set Job Schedule
			Write-Verbose "Configuring job schedule"
			if ($SettingsObject.schedule.expiryDate -and $SettingsObject.schedule.expiryTime) {
				$expiryTime = "$($SettingsObject.schedule.expiryDate)T$($SettingsObject.schedule.expiryTime)"
			}
			else {
				$expiryTime = $null
			}

			if ($SettingsObject.schedule.startTime -and $SettingsObject.schedule.startDate) {
				$startTime = "$($SettingsObject.schedule.startDate)T$($SettingsObject.schedule.startTime)"
			}
			else {
				$startTime = "$(((Get-Date).AddDays(1)).ToString("yyyy-MM-dd"))T00:00:00"
			}

			switch ($SettingsObject.schedule.frequency) {
				daily { $frequency = "Day" }
				monthly { $frequency = "Month" }
				weekly { $frequency = "Week" }
				Default { $frequency = "Day" }
			}

			$schedule = @{
				"expiryTime"       = $expiryTime;
				"frequency"        = $frequency;
				"interval"         = 1;
				"name"             = Get-CmAzResourceName -Resource "AutomationSchedule" -Architecture "Core" -Region $SettingsObject.location -Name delete-tagged-resource;
				"startTime"        = $startTime;
				"timeZone"         = "Europe/London";
				"advancedSchedule" = @{
					"weekDays"           = @();
					"monthDays"          = @();
					"monthlyOccurrences" = @()
				};
			}

			New-AzResourceGroupDeployment `
				-ResourceGroupName $automationService.resourceGroupName `
				-TemplateFile "$PSScriptRoot/Set-CmAzCoreAutomationDeleteResource.json" `
				-AutomationAccountName $automationService.name `
				-UpdateSchedule $schedule `
				-Force
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSitem);
	}
}
