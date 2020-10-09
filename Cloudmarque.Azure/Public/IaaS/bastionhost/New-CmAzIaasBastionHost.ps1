function New-CmAzIaasBastionHost {
	<#
		.Synopsis
		 Creates Bastion host

		.Description
		 Completes following:
			* This script creates Bastion hosts in resource group.
			* Creates 'AzureBastionSubnet' if not already exists.
			* Azure Bastion provisions directly in your Azure Virtual Network, providing Bastion host or jump server as-a-service and integrated connectivity to all virtual machines in your virtual networking using RDP/SSH directly from and through your browser and the Azure portal experience.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 IaaS

		.Example
		 New-CmAzIaasBastionHost -settingsFile "BastionHostyml"

		.Example
		 New-CmAzIaasBastionHost -settingsObject $BastionHostSettings
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[String]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[Object]$SettingsObject,
		[String]$TagSettingsFile
	)

	$ErrorActionPreference = "Stop"

	try {

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Create Bastion Host in resource group")) {

			if ($SettingsFile -and -not $SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (-not $SettingsFile -and -not $SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			$resourceGroupName = (Get-CmAzService -Service $SettingsObject.service.dependencies.resourceGroup -IsResourceGroup -ThrowIfUnavailable -ThrowIfMultiple).resourceGroupName

			$bastionWorkspace = @{
				"name" = ""; 
				"resourceId" = ""; 
				"location" = "";
			}

			if ($SettingsObject.service.dependencies.workspace) {

				Write-Verbose "Fetching workspace.."
				$workspace = Get-CmAzService -Service $SettingsObject.service.dependencies.workspace -ThrowIfUnavailable -ThrowIfMultiple
				$workspace = Get-AzOperationalInsightsWorkspace -Name $workspace.name -ResourceGroupName $workspace.resourceGroupName
				
				$bastionWorkspace.name = $workspace.name
				$bastionWorkspace.resourceId = $workspace.ResourceId
				$bastionWorkspace.location = $workspace.location
			}

			foreach($bastionHost in $SettingsObject.bastionHosts) {

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "vnet" -ResourceServiceContainer $bastionHost -IsDependency

				$bastionHost.vnetName = (Get-CmAzService -Service $bastionHost.service.dependencies.vnet -ThrowIfUnavailable -ThrowIfMultiple).name
				$vnetObject = Get-AzVirtualNetwork -Name $bastionHost.vnetName

				$bastionHost.bastionPublicIPName = Get-CmAzResourceName -Resource "PublicIPAddress" `
					-Architecture "IaaS" `
					-Region $SettingsObject.location `
					-Name $bastionHost.bastionHostName

				$bastionHost.bastionHostName = Get-CmAzResourceName -Resource "BastionHost" `
					-Architecture "IaaS" `
					-Region $SettingsObject.location `
					-Name $bastionHost.bastionHostName

				Write-Verbose "Checking if subnet 'AzureBastionSubnet' exists in Vnet"
				$bastionHostSubnet = Get-AzVirtualNetworkSubnetConfig -Name "AzureBastionSubnet" -VirtualNetwork $vnetObject -ErrorAction SilentlyContinue

				if (!$bastionHostSubnet) {
					Write-Verbose "AzureBastionSubnet not found!"
					if (!$bastionHost.bastionHostSubnetPrefix) {
						Write-Error "Subnet prefix for AzureBastionSubnet subnet not found. Please provide cidr"  -targetobject $bastionHost.bastionHostSubnetPrefix
					}
				}
				else {
					Write-Verbose "AzureBastionSubnet subnet Found!"
					$bastionHost.bastionHostSubnetPrefix = ""
				}

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "bastion" -ResourceServiceContainer $bastionHost
				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "bastionPublicIP" -ResourceServiceContainer $bastionHost
			}

			New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
				-TemplateFile "$PSScriptRoot\New-CmAzIaasBastionHost.json" `
				-BastionHostObject $SettingsObject `
				-Location $SettingsObject.location `
				-Workspace $bastionWorkspace `
				-Force

			$resourcesToSet = $SettingsObject.bastionHosts.bastionPublicIPName
			$resourcesToSet += $SettingsObject.bastionHosts.bastionHostName

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceIds $resourcesToSet
		}
		
		Write-Verbose "Finished!"
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem)
	}
}