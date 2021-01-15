function New-CmAzIaasVm {

	<#
		.Synopsis
		 Deploys multiple virtual machines, over multiple resource groups.

		.Description
		 Completes the following:
			 * Deploys multiple virtual machines over multiple resource groups.
			 * Encrypts all os and data disks using a key encryption key from a specified keyvault.
			 * Mounts all hard drives set up in the vms.
			 * Enables azure monitor and links all vms to the core log analytics workspace.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Parameter LocalAdminUsername
		 Local admin username for deployed vms, max length 20 characters.

		.Parameter LocalAdminPassword
		 Local admin passwords for deployed vms, requires three of the following character types:
			* Uppercase
			* Lowercase
			* Numeric
			* Special

		.Parameter TagSettingsFile
	     File path for the tag settings file to be converted into a tag settings object.

		.Component
		 IaaS

		.Example
		 New-CmAzIaasCompute -SettingsFile "c:/directory/settingsFile.yml" -LocalAdminUsername "username" -LocalAdminPassword "password"

		.Example
	 	 New-CmAzIaasCompute -SettingsObject $settings -LocalAdminUsername "username" -LocalAdminPassword "password"
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[String]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[Object]$SettingsObject,
		[parameter(Mandatory = $true)]
		[SecureString]$LocalAdminUsername,
		[parameter(Mandatory = $true)]
		[SecureString]$LocalAdminPassword,
		[String]$TagSettingsFile
	)

	$ErrorActionPreference = "Stop"

	try {

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Virtual Machines")) {

			if ($SettingsFile -and !$SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (!$SettingsFile -and !$SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			[Hashtable]$keyVaultDetails = $null

			if (!$SettingsObject.location) {
				Write-Error "Please provide a valid location." -Category InvalidArgument -CategoryTargetName "Location"
			}

			if (!$SettingsObject.service.dependencies.keyVault) {
				Write-Error "Please provide a valid keyvault tag." -Category InvalidArgument -CategoryTargetName "KeyVault.Tag"
			}

			$keyVaultService = Get-CmAzService -Service $SettingsObject.service.dependencies.keyvault -ThrowIfUnavailable -ThrowIfMultiple

			$keyVault = Get-AzKeyVault -Name $keyVaultService.name

			if (!$keyVault) {
				Write-Error "Cannot find key vault resource, ensure the provided tag is set on a keyvault." -Category InvalidArgument -CategoryTargetName "KeyVault.Tag"
			}
			else {
				Write-Verbose "Keyvault found.."
			}

			$keyEncryptionKey = Get-AzKeyVaultKey -VaultName $keyVault.vaultName -Name $SettingsObject.diskEncryptionKey

			if (!$keyEncryptionKey) {
				Write-Error "Cannot find key encryption key in keyvault." -Category InvalidArgument -CategoryTargetName "KeyVault.DiskEncryptionKey"
			}
			else {
				Write-Verbose "Encryption key found.."
			}

			$keyVaultDetails = @{
				KeyEncryptionKeyUrl = $keyEncryptionKey.id
				ResourceId          = $keyVault.resourceId;
				VaultUri            = $keyVault.vaultUri
			}

			$automationAccount = Get-CmAzService -Service $SettingsObject.service.dependencies.automation -ThrowIfUnavailable -ThrowIfMultiple

			$automationAccountRegistration = Get-AzAutomationRegistrationInfo `
				-ResourceGroupName $automationAccount.resourceGroupName `
				-AutomationAccountName $automationAccount.name  `
				-ErrorAction SilentlyContinue

			if (!$automationAccountRegistration) {
				Write-Error "Cannot find automation registration details." -Category InvalidArgument -CategoryTargetName "AutomationAccountTag"
			}
			else {
				Write-Verbose "Automation Registration details found.."
			}

			$automationAccount.registrationUrl = $automationAccountRegistration.endpoint
			$automationAccount.primaryKey = $automationAccountRegistration.primaryKey
			$automationAccount.nodeConfigurationName = $SettingsObject.desiredConfigName

			$workspace = Get-CmAzService -Service $SettingsObject.service.dependencies.workspace -ThrowIfUnavailable -ThrowIfMultiple

			$allResourceGroups = @()
			$allVirtualMachines = @()

			$daysOfWeek = [DayOfWeek].GetEnumNames()

			foreach ($resourceGroup in $SettingsObject.groups) {

				if (!$resourceGroup.name) {
					Write-Error "Please provide a valid resource group name." -Category InvalidArgument -CategoryTargetName "Groups.VirtualMachines.VirtualNetworkTag"
				}
				else {
					Write-Verbose "ResourceGroup found.."
				}

				if (!$resourceGroup.location) {
					$resourceGroup.location = $SettingsObject.location
				}

				$resourceGroup.name = Get-CmAzResourceName -Resource "ResourceGroup" -Architecture "IaaS" -Region $resourceGroup.location -Name $resourceGroup.name

				foreach ($virtualMachine in $resourceGroup.virtualMachines) {

					if (!$virtualMachine.location) {
						$virtualMachine.location = $resourceGroup.location
					}

					if (!$virtualMachine.plan) {
						$virtualMachine.plan = ''
					}

					$virtualMachine.resourceGroupName = $resourceGroup.name

					Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "vnet" -ResourceServiceContainer $virtualMachine.networking -IsDependency

					$virtualNetwork = Get-CmAzService -Service $virtualMachine.networking.service.dependencies.vnet -Region $virtualMachine.location -ThrowIfUnavailable -ThrowIfMultiple

					$virtualMachine.networking.virtualNetworkId = $virtualNetwork.resourceId

					Write-Verbose "Generating standardised resource names..."
					$virtualMachine.computerName = Get-CmAzResourceName -Resource "ComputerName" -Architecture "Core" -Region $virtualMachine.location -Name $virtualMachine.name -MaxLength 15
					$virtualMachine.nicName = Get-CmAzResourceName -Resource "NetworkInterfaceCard" -Architecture "IaaS" -Region $virtualMachine.location -Name $virtualMachine.name
					$virtualMachine.osDisk.Name = Get-CmAzResourceName -Resource "OSDisk" -Architecture "IaaS" -Region $virtualMachine.location -Name $virtualMachine.name
					$virtualMachine.fullName = Get-CmAzResourceName -Resource "VirtualMachine" -Architecture "IaaS" -Region $virtualMachine.location -Name $virtualMachine.name

					Write-Verbose "Building data disks..."
					$virtualMachine.DataDisks = @()

					if(!$virtualMachine.AzureDiskEncryption){
						$virtualMachine.AzureDiskEncryption = $false
					}

					for ($i = 0; $i -lt $virtualMachine.dataDiskSizes.count; $i++) {

						$virtualMachine.dataDisks += @{
							"Name"         = Get-CmAzResourceName -Resource "DataDisk" -Architecture "IaaS" -Region $virtualMachine.location -Name "$($virtualMachine.name)$($i + 1)";
							"Lun"          = $i + 1;
							"CreateOption" = "Empty";
							"DiskSizeGB"   = $virtualMachine.dataDiskSizes[$i]
						}
					}

					Write-Verbose "Building update tag.."
					if ($virtualMachine.updateGroup -and $virtualMachine.updateFrequency) {

						$scheduleSettings = Get-CmAzSettingsFile -Path "$PSScriptRoot/scheduleTypes.yml"

						$inValidScheduleSettings = 	!$scheduleSettings -or !$scheduleSettings.updateGroups[$virtualMachine.updateGroup] -or	(!$scheduleSettings.updateFrequencies[$virtualMachine.updateFrequency] -and $daysOfWeek -notcontains $virtualMachine.updateFrequency)

						if ($inValidScheduleSettings) {
							Write-Error "No valid schedule settings." -Category ObjectNotFound -CategoryTargetName "scheduleTypeSettingsObject"
						}

						$virtualMachine.updateTag = "$($virtualMachine.updateGroup)-$($virtualMachine.updateFrequency)".ToLower()
					}
					else {
						$virtualMachine.updateTag = ""
					}

					Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "vm" -ResourceServiceContainer $virtualMachine
					Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "nic" -ResourceServiceContainer $virtualMachine
				}

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "resourceGroup" -ResourceServiceContainer $resourceGroup

				$allResourceGroups += $resourceGroup;
				$allVirtualMachines += $resourceGroup.virtualMachines
			}

			Write-Verbose "Deploying virtual machines..."

			if (!$allVirtualMachines) {
				Write-Verbose "No valid virtual machines available for deployment..."
			}
			else {
				New-AzDeployment `
					-TemplateFile "$PSScriptRoot\New-CmAzIaasVm.ResourceGroups.json" `
					-ResourceGroups $allResourceGroups `
					-Location $SettingsObject.location

				# Cross resource group deployments for VMs appear to still to require the use of New-AzResourceGroupDeployment, instead of subscription level deployment
				# through New-AzDeployment, which doesn't seem right.
				# Deploying the same template through New-AzDeployment triggers a BadRequest: InvalidRequestFormat error.

				$credentials = @{
					"LocalAdminUsername" = ConvertFrom-SecureString $LocalAdminUsername -AsPlainText;
					"LocalAdminPassword" = ConvertFrom-SecureString $LocalAdminPassword -AsPlainText;
				}

				New-AzResourceGroupDeployment `
					-TemplateFile "$PSScriptRoot\New-CmAzIaasVm.json" `
					-ResourceGroupName $allResourceGroups[0].name `
					-Credentials $credentials `
					-VirtualMachines $allVirtualMachines `
					-WorkspaceId $workspace.resourceId `
					-KeyVault $keyVaultDetails `
					-AutomationAccount $automationAccount `
					-Force
			}

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceGroupIds $allResourceGroups.name

			Write-Verbose "Finished!"
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem)
	}
}