function New-CmAzDeployResource {
	
	<#
		.Synopsis
		 Resource group(s) or subscription level deployment using an ARM template and based on settings YAML.

		.Description
		 Completes the following based on Templates settings file:
			* Deploys resource group using New-AzResourceGroup. Resource group deployment can be disabled with templates.template.deployResourceGroup = false
			  or if templates.template.deploymentScope = subscription (in which case New-AzDeployment happens)
			* Generates New-AzResourceGroupDeployment -TemplateParameterObject from templates.template.parameters collection
			* Applies tags based on gobal tags (_names/tags.yml) and templates.template.tags settings

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 New-CmAzDeployResource -SettingsFile "c:/directory/settingsFile.yml"
		 New-CmAzDeployResource -SettingsObject $settings
		
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[string]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[object]$SettingsObject
	)

	$ErrorActionPreference = "stop"

	#region Nested Functions
	function Format-ResourceNameInCollection() {

		param(
			[parameter(Mandatory = $true)]
			[array]$resourceCollection
		)

		foreach ($resource in $resourceCollection) {
			if (!$resource.Name -or !$resource.architecture -or !$resource.resourceType -or !$resource.location -or !$resource.service) {
				Write-Error "Please ensure a ($collectionName) array has a name, an architecture, a resourceType a location and a service." -Category InvalidArgument -CategoryTargetName $resource.resourceType
			}

			$resource.name = Get-CmAzResourceName -Resource $resource.resourceType -Architecture $resource.architecture -Region $resource.location -Name $resource.name
		}
	}

	function Format-BudgetsCollection() {

		param(
			[parameter(Mandatory = $true)]
			[array]$budgets
		)

		foreach ($budget in $budgets) {

			Write-Verbose "Creating notifications for budget..."
			$notifications = @{ }

			$actionGroupResourceId = (Get-CmAzService -Service $budget.actionGroupService -ThrowIfUnavailable).resourceId

			for ($i = 0; $i -lt $budget.Thresholds.Count; $i++) {

				$notifications["Notification$i"] = @{
					enabled       = $true;
					operator      = "GreaterThanOrEqualTo";
					threshold     = $budget.Thresholds[$i];
					contactGroups = @($actionGroupResourceId);
					contactRoles  = @(
						"Owner",
						"Contributor",
						"Reader"
					)
				}
			}

			$budget.Notifications = $notifications
		}
	}

	function Format-ActionGroupCollection() {

		param(
			[parameter(Mandatory = $true)]
			[array]$ActionGroups,
			[parameter(Mandatory = $true)]
			[string]$location

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
					$receivers[$j][$nameKey] = Get-CmAzResourceName -Resource "ActionGroupReceiver" -Architecture "Core" -Region $location -Name "$($actionGroup[$nameKey])$($receiverType)-$($j)"
				}
			}

			$actionGroup[$nameKey] = Get-CmAzResourceName -Resource "ActionGroup" -Architecture "Core" -Region $location -Name $actionGroup[$nameKey]
		}
	}

	#endregion

	try {

		if ($SettingsFile -and -not $SettingsObject) {
			$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
		}
		elseif (-not $SettingsFile -and -not $SettingsObject) {
			Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
		}
		
		$templateResourceGroupName = $null
		$tagResourcesOnly = $false

		ForEach ($template in $SettingsObject.templates) {

			$deploymentScope = "resourceGroup"
			if ($null -ne $template.deploymentScope) { $deploymentScope = $template.deploymentScope }

			if ($deploymentScope.Equals("resourceGroup") -or $deploymentScope.Equals("subscription")) {
				Write-Verbose "Template deployment scope ($deploymentScope).."
			}
			else {
				Write-Error "Template.deploymentScope ($deploymentScope). Allowed values for Template.deploymentScope are 'resourceGroup' (default) or 'subscription." -Category InvalidArgument -CategoryTargetName $SettingsObject.deploymentScope
			}

			$deployResourceGroup = $true
			if ($null -ne $template.deployResourceGroup) { $deployResourceGroup = $template.deployResourceGroup } 
			Write-Verbose "Template.deployResourceGroup : ($deployResourceGroup)."
			
			if ($deploymentScope.Equals("resourceGroup")) {

				if (!$templateResourceGroupName -or !$templateResourceGroupName.Equals($template.resourceGroupName)) {

					Write-Verbose "Generating resource group name .."
					$resourceGroupName = Get-CmAzResourceName -Resource "ResourceGroup" `
						-Architecture $template.architecture `
						-Region $template.Location `
						-Name $template.resourceGroupName
			
					if ($deployResourceGroup) { 
						Write-Verbose "Deploying resource group ($resourceGroupName).."
						New-AzResourceGroup `
							-Name $resourceGroupName `
							-Location $template.Location `
							-Force

						$tagResourcesOnly = $false
						$templateResourceGroupName = $template.resourceGroupName
					}
					else {
						Write-Verbose "Not deploying resource group ($resourceGroupName) - template.deployResourceGroup : ($deployResourceGroup)."
						Write-Verbose "Typically this is for resources that re-use existing resource group & resource e.g. Azure firewall deployed to existing virtual network."
						$tagResourcesOnly = $true
					}

				}
				else {
					$tagResourcesOnly = $true
					Write-Verbose "Using same resource group for next template."
				}
			}

			$parameters = @{ }
			ForEach ($parameter in $template.parameters) {
				
				$parameterName = $parameter.parameter 
				$parameterValue = $parameter.value 
				$parameterType = $parameter.type 
				Write-Verbose "Parameter name ($parameterName), value ($parameterValue), type ($parameterType)."
			
				# get parameter value based on parameter type
				switch ($parameterType) {
					"resource" { 
						$parameterResourceType = $parameter.resourceType 
						Write-Verbose "Generating resource name for ($parameterResourceType) based on ($parameterValue) .."
						$resourceName = Get-CmAzResourceName `
							-Resource $parameterResourceType `
							-Architecture $template.architecture `
							-Region $template.Location `
							-Name $parameterValue

						$parameters.Add($parameterName, $resourceName)
					}
					"keyVaultSecret" { 
						#TODO Upcoming breaking changes in the cmdlet 'Get-AzKeyVaultSecret', version : '3.0.0', 'SecretValueText' depricated
						$secretValue = (Get-AzKeyVaultSecret -Name $parameterValue -VaultName (Get-CmAzService -Service $parameter.service -ThrowIfUnavailable).name).SecretValueText
						$parameters.Add($parameterName, $secretValue)
					}
					"userObjectID" { 
						$userObjectID = ""
						$azCtx = (Get-AzContext).Account
			
						switch ($azCtx.Type) {
							"ServicePrincipal" { $userObjectID = $azCtx.Id }
							"User" { $userObjectID = (Get-AzADUser -UserPrincipalName $azCtx.Id).Id }
						}
			
						$parameters.Add($parameterName, $userObjectID)
					}
					"serviceLookup.service" { 
						$serviceValue = Get-CmAzService -Service $parameterValue -ThrowIfUnavailable
						$parameters.Add($parameterName, $serviceValue)
					}
					"serviceLookup.name" { 
						$serviceValue = (Get-CmAzService -Service $parameterValue -ThrowIfUnavailable).name
						$parameters.Add($parameterName, $serviceValue)
					}
					"serviceLookup.resourceGroupName" { 
						$serviceValue = (Get-CmAzService -Service $parameterValue -ThrowIfUnavailable).resourceGroupName
						$parameters.Add($parameterName, $serviceValue)
					}
					"serviceLookup.resourceType" { 
						# $serviceValue = (Get-CmAzService -Service $parameterValue -Region $parameter.location  -ThrowIfUnavailable).resourceType
						$serviceValue = (Get-CmAzService -Service $parameterValue -ThrowIfUnavailable).resourceType
						$parameters.Add($parameterName, $serviceValue)
					}
					"serviceLookup.resourceId" { 
						$serviceValue = (Get-CmAzService -Service $parameterValue -ThrowIfUnavailable).resourceId
						$parameters.Add($parameterName, $serviceValue)
					}
					"int" { $parameters.Add($parameterName, [int]$parameterValue) }
					"integer" { $parameters.Add($parameterName, [int]$parameterValue) }
					"array" { 
						switch ($parameterValue) {
							"resource" { 
								Write-Verbose "Generating resource name only for array.."
								$parameterArray = $parameter[$parameterName]
								Format-ResourceNameInCollection -resourceCollection $parameterArray
								$parameters.Add($parameterName, $parameterArray)
							}
							"passThrough" { 
								Write-Verbose "Pass-through array unchanged.."
								$parameterArray = $parameter[$parameterName]
								$parameters.Add($parameterName, $parameterArray)
							}
							"actionGroups" {
								Write-Verbose "Generating Action Group array from settings.."
								$parameterArray = $parameter.ActionGroups
								Format-ActionGroupCollection -ActionGroups $parameterArray -location $template.location
								$parameters.Add($parameterName, $parameterArray)
							}
							"budgets" {
								Write-Verbose "Generating Budgets array from settings.."
								$parameterArray = $parameter.Budgets
								Format-BudgetsCollection -Budgets $parameterArray
								$parameters.Add($parameterName, $parameterArray)
							}
							default { 
								Write-Error "Unknow array parameter value ($parameterValue). Know values are: actionGroups, resource" -Category InvalidArgument -CategoryTargetName "SettingsObject"
							}
						}
					}
					default { $parameters.Add($parameterName, $parameterValue) }
				}
			}

			$ctx = Get-CmAzContext -ThrowIfUnavailable
			$templatePath = "{0}/_templates/{1}/{2}" -f $ctx.ProjectRoot, $template.templateCategory, $template.templateName

			if (!(Test-Path -Path "$templatePath")) {
				Write-Error -Message "Cannot find template ($templatePath)." -ErrorAction Stop 
			}

			if ($deploymentScope.Equals("resourceGroup")) {

				Write-Verbose "Deploying ($resourceGroupName) resources using ($templatePath) .."
				New-AzResourceGroupDeployment `
					-ResourceGroupName $resourceGroupName `
					-TemplateFile "$templatePath" `
					-TemplateParameterObject $parameters `
					-Force

				Set-CmAzResourceTag -SettingsObject $template -ResourceGroupName $resourceGroupName -TagResourcesOnly $tagResourcesOnly

			}
			else {

				Write-Verbose "Deploying resources at subscription scope using ($templatePath) .."
				New-AzDeployment `
					-Location $template.Location `
					-TemplateFile "$templatePath" `
					-TemplateParameterObject $parameters
			}
		}

		Write-Verbose "Finished!"

		return
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem);
	}
	
}
