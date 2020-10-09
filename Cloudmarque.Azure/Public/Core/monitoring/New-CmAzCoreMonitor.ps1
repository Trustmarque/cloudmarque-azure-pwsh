function New-CmAzCoreMonitor {

	<#
		.Synopsis
		 Deploys core monitoring and logging resources.

		.Description
		 Completes the following:
			* Deploys log analytics, app insights and storage account for NSG logs to the logging resource group.
			* Deploys management solutions for keyvaults, subscription activity, agent health, updates and VM insights to the logging resource group.
		 	* Deploys action groups and activity log alerts to the monitoring resource group.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 New-CmAzCoreMonitor -SettingsFile "c:/directory/settingsFile.yml"
		 New-CmAzCoreMonitor -SettingsObject $settings
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[string]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[object]$SettingsObject,
		[String]$TagSettingsFile
	)

	$ErrorActionPreference = "stop"

	function Format-ActionGroupCollection() {

		param(
			[parameter(Mandatory = $true)]
			[array]$ActionGroups
		)

		$receiverTypes = @("armRoles", "emails", "functions", "itsm", "logicApps", "notifications", "runbooks", "sms", "voice", "webhooks")
		$nameKey = "name"

		foreach ($actionGroup in $ActionGroups) {

			foreach ($receiverType in $receiverTypes) {

				$receivers = $actionGroup[$receiverType]

				if (!$receivers) {
					$actionGroup[$receiverType] = @()
					continue
				}

				for ($j = 0; $j -lt $receivers.Count; $j++) {
					$receivers[$j][$nameKey] = Get-CmAzResourceName -Resource "ActionGroupReceiver" -Architecture "Core" -Region $SettingsObject.Location -Name "$($actionGroup[$nameKey])$($receiverType)-$($j)"
				}
			}

			$actionGroup[$nameKey] = Get-CmAzResourceName -Resource "ActionGroup" -Architecture "Core" -Region $SettingsObject.Location -Name $actionGroup[$nameKey]
		}
	}

	try {

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Core Monitoring and Logging")) {

			if ($SettingsFile -and -not $SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (-not $SettingsFile -and -not $SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			if (!$SettingsObject.Name) {
				Write-Error "Please provide a valid name." -Category InvalidArgument -CategoryTargetName "Name"
			}

            if (!$SettingsObject.Location) {
                Write-Error "Please provide a valid location." -Category InvalidArgument -CategoryTargetName "Location"
            }

            if (!$SettingsObject.ActionGroups) {
                Write-Error "Please provide at least one action group." -Category InvalidArgument -CategoryTargetName "ActionGroups"
			}

			ForEach ($actionGroup in $SettingsObject.ActionGroups) {

				if(!$actionGroup.Name -or !$actionGroup.ShortName) {
					Write-Error "Please ensure a action group has a name, a shortname and at least one receiver." -Category InvalidArgument -CategoryTargetName "ActionGroups"
				}

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "actionGroup" -ResourceServiceContainer $actiongroup
			}

			Write-Verbose "Generating monitoring resource names.."
			$monitoringResourceGroupName = Get-CmAzResourceName -Resource "ResourceGroup" -Architecture "Core" -Region $SettingsObject.Location -Name "Monitoring-($($SettingsObject.Name))"
    		$serviceHealthAlertName = Get-CmAzResourceName -Resource "ServiceHealthAlert" -Architecture "Core" -Region $SettingsObject.Location -Name $SettingsObject.Name

			Write-Verbose "Deploying monitoring resource group ($monitoringResourceGroupName).."
			$resourceGroupServiceTag = @{ "cm-service" = $SettingsObject.service.publish.monitoringResourceGroup }

			New-AzResourceGroup `
				-Name $monitoringResourceGroupName `
				-Location $SettingsObject.Location `
				-Tag $resourceGroupServiceTag `
				-Force

			Write-Verbose "Formatting action group recievers.."
			Format-ActionGroupCollection -ActionGroups $SettingsObject.ActionGroups

			Write-Verbose "Deploying monitoring resources.."
			New-AzResourceGroupDeployment `
				-ResourceGroupName $monitoringResourceGroupName `
				-TemplateFile "$PSScriptRoot/New-CmAzCoreMonitor.Monitoring.json" `
				-ActionGroups $SettingsObject.ActionGroups `
				-ServiceHealthAlertName $serviceHealthAlertName `
				-ActivityLogAlertService $SettingsObject.service.publish.activityLogAlert `
				-Force

			Write-Verbose "Generating logging resource names.."
			$appInsightsName = Get-CmAzResourceName -Resource "ApplicationInsights" -Architecture "Core" -Region $SettingsObject.Location -Name $SettingsObject.Name
			$loggingResourceGroupName = Get-CmAzResourceName -Resource "ResourceGroup" -Architecture "Core" -Region $SettingsObject.Location -Name "Logging-($($SettingsObject.Name))"
			$storageName = Get-CmAzResourceName -Resource "StorageAccount" -Architecture "Core" -Region $SettingsObject.Location -Name $SettingsObject.Name -MaxLength 24
			$workspaceName = Get-CmAzResourceName -Resource "LogAnalyticsworkspace" -Architecture "Core" -Region $SettingsObject.Location -Name $SettingsObject.Name

			Write-Verbose "Deploying logging resource Group ($loggingResourceGroupName).."
			$resourceGroupServiceTag = @{ "cm-service" = $SettingsObject.service.publish.loggingResourceGroup }
			
			New-AzResourceGroup `
				-Name $loggingResourceGroupName `
				-Location $SettingsObject.Location `
				-Tag $resourceGroupServiceTag `
				-Force

			Write-Verbose "Deploying logging resources.."
			New-AzResourceGroupDeployment `
				-ResourceGroupName $loggingResourceGroupName `
				-TemplateFile "$PSScriptRoot/New-CmAzCoreMonitor.Logging.json" `
				-AppInsightsName $appInsightsName `
				-StorageAccountName $storageName `
				-ServiceContainer $SettingsObject.service.publish `
				-WorkspaceName $workspaceName `
				-Force

			Write-Verbose "Setting advisor configuration cpu threshold.."

			$validPercentages = @(0, 5, 10, 15, 20)

			if(!$SettingsObject.AdvisorLowCPUThresholdPercentage -or $validPercentages -NotContains $SettingsObject.AdvisorLowCPUThresholdPercentage) {
				Write-Error "Please provide a valid low cpu threshold percentage, valid percentages are 0, 5, 10, 15, 20." -Category InvalidArgument -CategoryTargetName "AdvisorLowCPUThresholdPercentage"
			}

			Set-AzAdvisorConfiguration -LowCpuThreshold $SettingsObject.AdvisorLowCPUThresholdPercentage

			$resourceGroupsToSet = @($monitoringResourceGroupName)
			$resourceGroupsToSet += $loggingResourceGroupName

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceGroupIds $resourceGroupsToSet

			Write-Verbose "Finished!"
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem);
	}
}