function Set-CmAzCoreTag {

	<#
		.Synopsis
		 Set tags on resources.

		.Description
		 Sets mandatory and custom tags on either specific resources or all the resources in a resource group.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 Set-CmAzCoreTag -SettingsFile "c:/directory/settingsFile.yml"

		.Example
		 Set-CmAzCoreTag -SettingsObject $settings
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

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Set tags for resources")) {

			if ($SettingsFile -and !$SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (!$SettingsFile -and !$SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			Write-Verbose "Checking that the expected mandatory tags exist and are not empty..."
			$expectedMandatoryTagKeys = @("cm-owner", "cm-charge", "cm-apps")

			$mandatoryTagsVariableName = "Tags.Mandatory"

			$missingMandatoryKeys = $expectedMandatoryTagKeys | Where-Object { $SettingsObject.Tags.Mandatory.Keys -NotContains $_ }

			if ($missingMandatoryKeys) {
				Write-Error "$([string]$missingMandatoryKeys) is missing from the mandatory tags section." -Category InvalidArgument -CategoryTargetName $mandatoryTagsVariableName
			}

			$cmazContext = Get-CmAzContext

			$sourceTypeInfo = $cmazcontext.builddefinitionname.trim(")").split("(")

			$SettingsObject.Tags.Mandatory["cm-source"] = "$($sourceTypeInfo[0]) $($cmazContext.date)"
			$SettingsObject.Tags.Mandatory["cm-type"] = $sourceTypeInfo[1]

			foreach ($key in $SettingsObject.Tags.Mandatory.Keys) {

				$tagValue = $SettingsObject.Tags.Mandatory[$key]

				if(!$tagValue) {
					Write-Error "Mandatory Tag - $key is null. Please set the appropriate Value in settings." -Category InvalidArgument -CategoryTargetName $mandatoryTagsVariableName
				}
				else {
					Write-Verbose "Mandatory Tag - $key will be set as $tagValue..."
				}
			}

			$allTags = $SettingsObject.Tags.Mandatory

			Write-Verbose "Setting custom tags..."
			if ($SettingsObject.Tags.Custom) {

				foreach ($customTagKey in $SettingsObject.Tags.Custom.Keys) {

					$Value = $SettingsObject.Tags.Custom[$customTagKey]
					Write-verbose "Tag - $customTagKey will be set as $Value..."
				}

				$allTags += $SettingsObject.Tags.Custom
			}

			$resources = @()

			Write-Verbose "Fetching resources to be set..."
			if ($SettingsObject.ResourceIds) {

				foreach ($resourceId in $SettingsObject.ResourceIds) {

					Write-Verbose "Fetching $resourceId..."
					if($resourceId.startsWith("/subscriptions/") -Or $resourceId -Contains "/") {
						$existingResources = Get-AzResource -ResourceID $resourceId -ErrorAction Continue
					}
					else {
						$existingResources = Get-AzResource -Name $resourceId -ErrorAction Continue
					}

					if(!$existingResources) {
						Write-Error "Issue locating resource: $resourceId." -Category ObjectNotFound -CategoryTargetName $resourceId
					}

					$resources += $existingResources
				}
			}
			elseif ($SettingsObject.ResourceGroupIds) {

				foreach ($resourceGroupId in $SettingsObject.ResourceGroupIds) {

					$resourceGroup = $null

					try {
						Write-Verbose "Fetching resource group $($resourceGroupId)..."
						$resourceGroup = Get-AzResourceGroup -ResourceGroupName $resourceGroupId
					}
					catch {
						Write-Error "Issue locating resource group: $($resourceGroupId)." -Category ObjectNotFound -CategoryTargetName "ResourceGroupIds"
					}

					$tagsToSet = @{}
					$tagsToSet += $allTags

					if($resourceGroup.tags) {
						$tagsToSet = Merge-HashTables -HashtableToFilter $resourceGroup.tags -HashtableToAdd $tagsToSet
					}

					Write-Verbose "Setting tags for $($resourceGroupId)..."
					Set-AzResourceGroup -Name $resourceGroupId -Tag $tagsToSet

					try {
						Write-Verbose "Fetching resources in $($resourceGroupId)..."
						$existingResources += Get-AzResource -ResourceGroupName $resourceGroupId
					}
					catch {
						Write-Error "Issue locating resources in resource group: $($resourceGroupId)." -Category ObjectNotFound -CategoryTargetName "ResourceGroupIds"
					}

				}
			}
			else {
				Write-Error "Provide resource id or resource group name." -Category InvalidArgument -CategoryTargetName "ResourceGroupIds"
			}

			Write-Verbose "Tagging initiated.."

			$resources  | ForEach-Object -Parallel {

				$tagsToSet = @{}
				$tagsToSet += $using:allTags

				$resource = $_

				. "$using:PSScriptRoot/../../../Private/Utility/Merge-Hashtables.ps1"

				if($resource.tags) {
					$tagsToSet = Merge-HashTables -HashtableToFilter $resource.tags -HashtableToAdd $tagsToSet
				}

				Write-Verbose "Setting tags for $($resource.name)..."
				if ($resource.ResourceType -eq 'Microsoft.Network/Frontdoors') {

					# Work around as Azure FrontDoor does not support setting tags via PATCH operations
					Set-AzFrontDoor -ResourceGroupName $resource.ResourceGroupName -Name $resource.Name -Tag $tagsToSet > $null
				}
				else {
					Set-AzResource -ResourceID $resource.Id -Tag $tagsToSet -Force > $null
				}
			}

			Write-Verbose "Finished tagging resources!"
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem);
	}
}