function New-CmAzCoreKeyVault {

	<#
		.Synopsis
		 Creates keyvaults for a specified resource group in the current subscription.

		.Description
		 Completes the following:
			* Deploys multiple keyvaults in multiple locations to a specified resource group.
			* Adds diagnostic settings linking the keyvaults to the core workspace.
			* Adds activity log alert rules for whenever an auditevent is raised in any of the keyvaults.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

        .Example
		 New-CmAzCoreKeyVault -SettingsFile "c:/directory/settingsFile.yml"

		.Example
         New-CmAzCoreKeyVault -SettingsObject $settings
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[String]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[Object]$SettingsObject,
		[String]$TagSettingsFile
	)

	$ErrorActionPreference = "Stop"

    try {

		if($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Keyvault")) {

			if ($SettingsFile -and !$SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (!$SettingsFile -and !$SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			if (!$SettingsObject.resourceGroupName) {
				Write-Error "Please provide a valid resource group name." -Category InvalidArgument -CategoryTargetName "ResourceGroupName"
			}

			if (!$SettingsObject.location) {
				Write-Error "Please provide a valid location." -Category InvalidArgument -CategoryTargetName "Location"
			}

			if (!$SettingsObject.keyVaults) {
                Write-Error "Please provide at least one keyvault." -Category InvalidArgument -CategoryTargetName "Keyvaults"
			}

			Write-Verbose "Generating standardised Key Vault names..."
			ForEach ($keyVault in $SettingsObject.keyVaults) {

				if(!$keyVault.name -or !$keyVault.type -or !$keyVault.location) {
					Write-Error "Please ensure a keyvault has a name, a type and a location." -Category InvalidArgument -CategoryTargetName "Keyvaults"
				}

				$keyVault.name = Get-CmAzResourceName -Resource "KeyVault" -Architecture "Core" -Region $keyVault.location -Name $keyVault.name -MaxLength 24
			
				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "keyvault" -ResourceServiceContainer $keyVault
				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "activityLogAlert" -ResourceServiceContainer $keyVault
			}

			Write-Verbose "Generating keyvault resource group name..."
			$keyVaultResourceGroup = Get-CmAzResourceName -Resource "ResourceGroup" -Architecture "Core" -Region $SettingsObject.location -Name $SettingsObject.resourceGroupName

			Write-Verbose "Deploying keyvault resource group..."
			$resourceGroupServiceTag = @{ "cm-service" = $SettingsObject.service.publish.resourceGroup }
			New-AzResourceGroup -Location $SettingsObject.location -Name $keyVaultResourceGroup -Tag $resourceGroupServiceTag -Force

			$userObjectID = ""
			$azCtx = (Get-AzContext).account

			switch ($azCtx.type)
			{
				"ServicePrincipal" { $userObjectID = $azCtx.id }
				"User" { $userObjectID = (Get-AzADUser -UserPrincipalName $azCtx.id).id }
			}

			$workspace = Get-CmAzService -Service $SettingsObject.service.dependencies.workspace -ThrowIfUnavailable -ThrowIfMultiple
			$actionGroup = Get-CmAzService -Service $SettingsObject.service.dependencies.actiongroup -ThrowIfUnavailable -ThrowIfMultiple
			
			Write-Verbose "Deploying keyvaults..."
			New-AzResourceGroupDeployment `
				-TemplateFile "$PSScriptRoot\New-CmAzCoreKeyVault.json" `
				-ResourceGroupName $keyVaultResourceGroup `
				-ActionGroup $actionGroup `
				-Keyvaults $SettingsObject.KeyVaults `
				-ObjectId $UserObjectID `
				-Workspace $workspace `
				-Force

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceGroupIds $keyVaultResourceGroup

			Write-Verbose "Finished!"
		}
    }
    catch {
        $PSCmdlet.ThrowTerminatingError($PSItem);
    }
}
