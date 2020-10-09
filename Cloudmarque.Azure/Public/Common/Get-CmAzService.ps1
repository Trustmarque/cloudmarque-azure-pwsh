function Get-CmAzService {

	<#
		.Synopsis
		 An implementation of the Service Locator pattern in PowerShell using Azure Tags to identify services.

		.Description
		 Finds Azure Resources based on the tag value of "cm-service", alongside additional filters for service type and
		 region. Service names can be anything, and can therefore be shaped to a specific organisation's context and uses.

		 The service locator pattern provides a canonical naming mechanism for Azure Resources which allows a component-based
		 deployments, where each component is responsible for locating its own dependencies. A deployment may then fail if its
		 dependencies are not deployed.

		.Component
		 Common

		.Parameter ServiceKey
		 Represents the service key to search for. By default, this is "cm-service", but it can be overridden. Do so with
		 caution, as this breaks a fundamental convention used in the Cloudmarque framework.

		.Parameter Service
		 Represents the service name to search for.

		.Parameter Region
		 A region to search within - allows the same service to be deployed in multiple regions, or other commands to
		 validate that the service is available in the specified region.

		.Parameter IsResourceGroup
		 Indicates whether the resource to be located is a resource group.

		.Parameter ThrowIfUnavailable
		 Indicates that an exception should be thrown if the specified resource is unavailable. This is useful in
		 scripts where dependencies are mandatory prior to provisioning. By default this is false, no service will
		 be returned but a "not found" message will be written in verbose mode.

		.Example
		 Find a single keyvault
		 $keyVault = Get-CmAzService -Service "core-keys" -Region "USEast" -ThrowIfMultiple

		.Example
		 Find a single storage account for NSG logs
		 $storageAccount = Get-CmAzService -Service "core-monitoring-logs-nsg" -Region "USEast" -ThrowIfMultiple

		.Example
		 Find a set of vms
		 $vms = Get-CmAzService -Service "core.mySetOfVms" -Region "UKSouth"
	#>

	[CmdletBinding()]
	[OutputType([Hashtable])]
	param(
		[String]
		[AllowEmptyString()]
		$Service,

		[String]
		$ServiceKey = "cm-service",

		[String]
		$Region,

		[Switch]
		$IsResourceGroup,

		[Switch]
		$ThrowIfUnavailable,

		[Switch]
		$ThrowIfMultiple
	)

	if(!$Service) {
		Write-Error "Value for $ServiceKey not provided, unable to find existing resources via the service locator. `nPlease check that your dependencies are correctly populated."
	}

	Get-CmAzContext -RequireAzure -ThrowIfUnavailable | Out-Null

	$existingResources = @{}
	$tag = "$ServiceKey : $Service"

	if ($IsResourceGroup) {
		Write-Verbose "Searching for resource group with tag $($tag)"
		$existingResources = Get-AzResourceGroup -Tag @{ $ServiceKey = $Service }
	}
	else {
		Write-Verbose "Searching for resource with tag $($tag)"
		$existingResources = Get-AzResource -TagName $ServiceKey -TagValue $Service
	}

	if ($existingResources -is [system.array] -and $Region) {

		$Region = $Region.replace(" ", "")
		$existingResources = $existingResources | Where-Object { $_.location -Eq $Region }
	}

	if($existingResources.length -gt 1) {

		if ($ThrowIfMultiple) {
			Write-Error "More than one resource returned for $tag, please check your resource tagging."
		}
		else {

			$resources = @()

			foreach ($existingResource in $existingResources) {
				$resources += ConvertTo-HashTable $existingResource
			}

			$resources
		}
	}
	elseif ($existingResources.length -eq 1) {
		ConvertTo-HashTable -objectToConvert $existingResources
	}
	elseif ($ThrowIfUnavailable) {
		Write-Error "Service not found. No resource with tag `"$($tag)`" could be found." -Category InvalidArgument -CategoryTargetName "ServiceKey : Service"
	}
	else {
		Write-Verbose "Service not found. No resource with tag `"$($tag)`" could be found."
	}
}