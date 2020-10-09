function New-CmAzIaasNetworking {

	<#
		.Synopsis
		 Creates networking solution

		.Description
		 Completes following:
			* Creates vnets and subnets. Optionally attach nsg and route tables to subnet.
			* Creates route tables and routes.
			* Creates network security groups.
			* Creates resource groups if doesn't exist.
			* Configure resources in mulitple resource groups at once.
			* Ability to optionally configure networking component independently.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter VnetsCsvFile
		 File path for the csv containing virtual network configurations.
		 Required headers: resourceGroupName|location(optional)|vnetName|addressSpace|subnetName|cidr|networkSecurityGroup|routeTable.

		.Parameter RouteTablesCsvFile
		 File path for the csv containing route table configurations.
		 Required headers: resourceGroupName|location(optional)|tableName|routeName|cidr|nextHopType|nextHopIpAddress|notes

		.Parameter NsgsCsvFile
		 File path for the csv containing virtual network security group configurations.
		 Required headers: resourceGroupName|location(optional)|nsgName|ruleName|priority|direction|sourceIp|sourcePort|destinationIp|destinationPort|protocol|Access|Description

		.Parameter ResourceGroupsCsvFile
		 File path for the csv containing resource Group and location mapping. By default location of first vnet is used to create resource group.
		 Required headers: resourceGroupName|location

		.Component
		 IaaS

		.Example
		 New-CmAzIaasNetworking -settingsFile "networking.yml"

		.Example
		 New-CmAzIaasNetworking -VnetsCsvFile "vnet.csv" -RouteTablesCsvFile "routeTable.csv" -NsgsCsvFile "nsg.csv" -ResourceGroupCsvFile resourceGroup.csv -Confirm:$false

		.Example
		 New-CmAzIaasNetworking -VnetsCsvFile "vnet.csv" -RouteTablesCsvFile "routeTable.csv" -NsgsCsvFile "nsg.csv" -Confirm:$false

		.Example
		 New-CmAzIaasNetworking -RouteTablesCsvFile "routeTable.csv" -Confirm:$false

	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings Yml File")]
		[String]$SettingsFile,
		[parameter(Mandatory = $false, ParameterSetName = "Settings CSV File")]
		[String]$VnetsCsvFile,
		[parameter(Mandatory = $false, ParameterSetName = "Settings CSV File")]
		[String]$RouteTablesCsvFile,
		[parameter(Mandatory = $false, ParameterSetName = "Settings CSV File")]
		[String]$NsgsCsvFile,
		[parameter(Mandatory = $false, ParameterSetName = "Settings CSV File")]
		[String]$ResourceGroupsCsvFile,
		[String]$TagSettingsFile
	)

	$ErrorActionPreference = "Stop"

	try {

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Create networking solution")) {

			if ($SettingsFile -and -not $SettingsObject -and -not $VnetsCsvFile -and -not $RouteTablesCsvFile -and -not $NsgsCsvFile ) {
				Write-Verbose "Importing setting from Yml file"
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (-not $SettingsFile -and -not $SettingsObject -and -not $VnetsCsvFile -and -not $RouteTablesCsvFile -and -not $NsgsCsvFile ) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			$resourceGroupObjectArray = [System.Collections.ArrayList]@()

			# Code to Create Object from CSV

			if ($VnetsCsvFile -or $RouteTablesCsvFile -or $NsgsCsvFile -and !$SettingsObject)	{

				if ($VnetsCsvFile) {
					Write-Verbose "Vnet CSV Found."
					$vnetObjectFile = Import-Csv -Path $VnetsCsvFile

					if ($vnetObjectFile.count -eq 1) {
						$vnetFile = @($vnetObjectFile)
					}
					else {
						$vnetFile = $vnetObjectFile
					}
				}
				else {
					Write-Verbose "Vnet CSV not found."
					$vnetFile = @()
				}

				if ($RouteTablesCsvFile) {
					Write-Verbose "Route Table CSV Found."
					$routeTablesFile = Import-Csv -Path $RouteTablesCsvFile
				}
				else {
					Write-Verbose "Route Table CSV not Found."
					$routeTablesFile = @()
				}

				if ($NsgsCsvFile) {
					Write-Verbose "Nsg CSV Found."
					$nsgFile = Import-Csv -Path $NsgsCsvFile
				}
				else {
					Write-Verbose "Nsg CSV Not Found."
					$nsgFile = @()
				}

				if ($ResourceGroupsCsvFile) {
					Write-Verbose "Resource Group CSV Found."
					$resourceGroupslocation = Import-Csv -Path $ResourceGroupsCsvFile
				}

				Write-Verbose "Starting file merge."
				[System.Collections.ArrayList]$mergedFile = $vnetFile + $nsgFile + $routeTablesFile

				if ($nsgFile) {
					$nsgCsv = $mergedFile | Group-Object nsgName

					foreach ($nsg in ($nsgCsv | Where-Object { $_.name -like "*.csv" } )) {
						Write-Verbose "NSG: external CSV detected"

						foreach ($externalNsg in $nsg.Group) {
							$interimNsgCsvPath = "$(Split-Path $NsgsCsvFile)/$($nsg.Name)"
							$interimNsgCsvPath | Write-Verbose
							$interimNsgFile = Import-Csv -Path $interimNsgCsvPath
							$interimNsg = $interimNsgFile | Group-Object nsgName
							$interimNsgObjectArray = [System.Collections.ArrayList]@()

							foreach ($internalNsg in $interimNsg.Group) {

								$interimNsgObject = New-Object -TypeName psobject -Property @{
									"resourceGroupName" = $internalNsg.resourceGroupName;
									"nsgName"           = $internalNsg.nsgName;
									"location"          = $internalNsg.location;
									"servicePublish"    = $internalNsg.servicePublish;
									"ruleName"          = $externalNsg.ruleName;
									"priority"          = $externalNsg.priority;
									"direction"         = $externalNsg.direction;
									"sourceIp"          = $externalNsg.sourceIp;
									"sourcePort"        = $externalNsg.sourcePort;
									"destinationIp"     = $externalNsg.destinationIp;
									"destinationPort"   = $externalNsg.destinationPort;
									"protocol"          = $externalNsg.protocol;
									"Access"            = $externalNsg.Access;
									"Description"       = $externalNsg.Description
								}

								$interimNsgObjectArray.add($interimNsgObject) > $Null
							}

							Write-Verbose "Starting merge.."
							$mergedFile.Remove($externalNsg)
							$mergedFile += $interimNsgObjectArray
						}
					}
				}

				$resourceGroupsFile = $mergedFile | Group-Object -Property resourceGroupName

				# Code to add vnet in the object
				function subnetObject {
					param(
						[Object]$subnetGroup,
						[String]$subnetName
					)

					$subnetObject = @{
						subnetName           = $subnetName;
						cidr                 = $subnetGroup.cidr;
						networkSecurityGroup = $subnetGroup.networkSecurityGroup;
						routeTable           = $subnetGroup.routeTable;
					}
					$subnetObject
				}

				function vnetObject {
					param(
						[Object]$vnetGroup,
						[String]$vnetName
					)

					$subnetObjectList = [System.Collections.ArrayList]@()
					$subnetGroup = $vnetGroup | Group-Object subnetName

					foreach ($subnet in $subnetGroup) {
						$subnetObject = subnetObject -subnetGroup $subnet.Group -subnetName $subnet.Name
						$subnetObjectList.Add($subnetObject) > $Null
					}

					if ($vnetGroup.addressSpace.count -gt 1) {
						$addressSpace = $vnetGroup.addressSpace[0].ToString().split(',')
					}
					else {
						$addressSpace = $vnetGroup.addressSpace.ToString().split(',')
					}

					if ($vnetGroup.location.count -gt 1) {
						$location = $vnetGroup.location[0]
					}
					else {
						$location = $vnetGroup.location
					}

					if ($vnetGroup.servicePublish.count -gt 1) {
						$servicePublish = $vnetGroup.servicePublish[0]
					}
					else {
						$servicePublish = $vnetGroup.servicePublish
					}

					if ($vnetGroup.resourceGroupServicePublish.count -gt 1) {
						$resourceGroupServicePublish = $vnetGroup.resourceGroupServicePublish[0]
					}
					else {
						$resourceGroupServicePublish = $vnetGroup.resourceGroupServicePublish
					}

					$vnetObject = @{
						vnetName     = $vnetName;
						addressSpace = $addressSpace;
						subnets      = $subnetObjectList;
						location     = $location;
						service      = @{
							publish = @{
								vnet          = $servicePublish;
								resourceGroup = $resourceGroupServicePublish
							}
						}
					}

					$vnetObject
				}

				# Code to add UDR in the object
				function routeObject {
					param(
						[Object]$routeGroup,
						[String]$routeName
					)

					$routeObject = @{
						routeName        = $routeName;
						cidr             = $routeGroup.cidr;
						nextHopType      = $routeGroup.nextHopType;
						nextHopIpAddress = $routeGroup.nextHopIpAddress
					}

					$routeObject
				}
				function routeTableObject {
					param(
						[Object]$routeTableGroup,
						[String]$tableName
					)

					$routeObjectList = [System.Collections.ArrayList]@()
					$routeGroup = $routeTableGroup | Group-Object routeName

					foreach ($route in $routeGroup) {
						$routeObject = routeObject -routeGroup $route.Group -routeName $route.Name
						$routeObjectList.Add($routeObject) > $Null
					}

					if ($routeTableGroup.location.count -gt 1) {
						$location = $routeTableGroup.location[0]
					}
					else {
						$location = $routeTableGroup.location
					}

					if ($routeTableGroup.servicePublish.count -gt 1) {
						$servicePublish = $routeTableGroup.servicePublish[0]
					}
					else {
						$servicePublish = $routeTableGroup.servicePublish
					}

					if ($routeTableGroup.resourceGroupServicePublish.count -gt 1) {
						$resourceGroupServicePublish = $routeTableGroup.resourceGroupServicePublish[0]
					}
					else {
						$resourceGroupServicePublish = $routeTableGroup.resourceGroupServicePublish
					}

					$routeTableObject = @{
						tableName = $tableName;
						routes    = $routeObjectList;
						location  = $location;
						service   = @{
							publish = @{
								routeTable    = $servicePublish;
								resourceGroup = $resourceGroupServicePublish
							}
						}
					}

					$routeTableObject
				}

				# Code to add Nsg rules in the object
				function nsgruleObject {
					param(
						[Object]$nsgGroupObject
					)

					$nsgruleObject = @{
						ruleName        = $nsgGroupObject.ruleName;
						Description     = $nsgGroupObject.Description;
						priority        = $nsgGroupObject.priority;
						direction       = $nsgGroupObject.direction;
						sourceIp        = $nsgGroupObject.sourceIp.ToString().split(',');
						sourcePort      = $nsgGroupObject.sourcePort.ToString().split(',');
						destinationIp   = $nsgGroupObject.destinationIp.ToString().split(',');
						destinationPort = $nsgGroupObject.destinationPort.ToString().split(',');
						protocol        = $nsgGroupObject.protocol;
						Access          = $nsgGroupObject.Access
					}

					$nsgruleObject
				}

				function nsgObject {
					param(
						[Object]$nsgGroup,
						[String]$nsgName
					)

					$nsgruleObjectList = [System.Collections.ArrayList]@()
					$nsgGroupObject = $nsgGroup | Group-Object ruleName

					foreach ($nsg in $nsgGroupObject) {

						if ($nsg.count -gt 1) {
							Write-Error "Rule name not unique : '$($nsg.Name) in '$($nsg.Group.nsgName[0])' for Resource Group: '$($nsg.Group.resourceGroupName[0])'" -CategoryTargetName $nsg.Name -ErrorAction Stop
						}
						$nsgruleObject = nsgruleObject -nsgGroupObject $nsg.Group
						$nsgruleObjectList.Add($nsgruleObject) > $Null
					}

					if ($nsgGroup.location.count -gt 1) {
						$location = $nsgGroup.location[0]
					}
					else {
						$location = $nsgGroup.location
					}

					if ($nsgGroup.servicePublish.count -gt 1) {
						$servicePublish = $nsgGroup.servicePublish[0]
					}
					else {
						$servicePublish = $nsgGroup.servicePublish
					}

					if ($nsgGroup.resourceGroupServicePublish.count -gt 1) {
						$resourceGroupServicePublish = $nsgGroup.resourceGroupServicePublish[0]
					}
					else {
						$resourceGroupServicePublish = $nsgGroup.resourceGroupServicePublish
					}

					$nsgObject = @{
						nsgName  = $nsgName;
						rules    = $nsgruleObjectList;
						location = $location;
						service  = @{
							publish = @{
								networkSecurityGroup = $servicePublish;
								resourceGroup        = $resourceGroupServicePublish
							}
						}
					}

					$nsgObject
				}

				# Create a unified Resource Group collection
				foreach ($ResourceGroup in ($resourceGroupsFile | Where-Object { $_.Name -notlike '' })) {

					if ($ResourceGroup.Name) {
						# Adding Vnets
						Write-Verbose "working for $($ResourceGroup.Name)"
						$vnetsGroup = $ResourceGroup.Group | Group-Object vnetName

						Write-Verbose "'$($ResourceGroup.Name)' has vnets = '$($($vnetsGroup.Name -notlike '').count)'"
						$vnetObjectArray = [System.Collections.ArrayList]@()

						foreach ($vnet in $vnetsGroup) {

							if ($vnet.name) {
								$vnetObject = vnetObject -vnetGroup $vnet.Group -vnetName $vnet.Name
								Write-Verbose "Adding vnet = '$($vnet.Name)' to RG = '$($ResourceGroup.Name)'"
								$vnetObjectArray.Add($vnetObject) > $Null
							}
						}

						# Adding UDR
						$routeTableGroup = $ResourceGroup.Group | Group-Object tableName

						Write-Verbose "'$($ResourceGroup.Name)' has route tables = '$($($routeTableGroup.Name -notlike '').count)'"
						$routeTableObjectArray = [System.Collections.ArrayList]@()

						foreach ($routeTable in $routeTableGroup) {

							if ($routeTable.name) {
								$routeTableObject = routeTableObject -routeTableGroup $routeTable.Group -tableName $routeTable.Name
								Write-Verbose "Adding UDR = '$($routeTable.Name)' to RG = '$($ResourceGroup.Name)'"
								$routeTableObjectArray.Add($routeTableObject) > $Null
							}
						}

						# Adding NSG
						$nsgGroup = $ResourceGroup.Group | Group-Object nsgName
						Write-Verbose "'$($ResourceGroup.Name)' has network security groups = '$($($nsgGroup.Name -notlike '').count)'"
						$nsgObjectArray = [System.Collections.ArrayList]@()

						foreach ($nsg in $nsgGroup) {

							if ($nsg.name) {
								$nsgObject = nsgObject -nsgGroup $nsg.Group -nsgName $nsg.Name
								Write-Verbose "Adding nsg = '$($nsg.Name)' to RG = '$($ResourceGroup.Name)'"
								$nsgObjectArray.Add($nsgObject) > $Null
							}
						}

						# Default values if required for ARM template sanity checks
						if (!$vnetObjectArray) {
							$vnetObjectArray = @(@{vnetName = "none"; location = ""; addressSpace = @("10.10.0.0/24"); subnets = @(@{subnetName = "none"; cidr = "0.0.0.0/0" }) })
						}

						if (!$routeTableObjectArray) {
							$routeTableObjectArray = @(@{tableName = "none"; location = ""; routes = @(@{routeName = "none"; cidr = "0.0.0.0/0"; nextHopType = "VirtualAppliance"; nextHopIpAddress = "10.10.10.10" }) })
						}

						if (!$nsgObjectArray) {
							$nsgObjectArray = @(@{nsgName = "none"; location = ""; rules = @(@{ruleName = "none"; description = "none"; priority = "none"; direction = "none"; sourceIp = "10.10.10.10"; sourcePort = 3389; destinationIp = "10.10.10.11"; destinationPort = 3389; protocol = "Tcp"; Access = "allow" }) })
						}

						# Build Resource Group Config
						$ifResourceGroupExists = Get-AzResourceGroup -Name $ResourceGroup.Name -ErrorAction SilentlyContinue

						if (!$ifResourceGroupExists) {

							$RGlocation = ($resourceGroupslocation | Where-Object { $_.resourceGroupName -like $ResourceGroup.Name }).location
							$resourceGroupServicePublish = ($resourceGroupslocation | Where-Object { $_.resourceGroupName -like $ResourceGroup.Name }).resourceGroupServicePublish

							if (!$RGlocation -and $vnetObjectArray[0].location ) {
								$RGlocation = $vnetObjectArray[0].location
							}

							if (!$RGlocation) {
								Write-Error "Resource Group doesnt exist and a location is also not provided to create one."
							}

							if (!$resourceGroupServicePublish) {
								$resourceGroupServicePublish = $vnetObjectArray.service.publish.resourceGroup | Where-Object { $_ -notlike '' }
							}
							if (!$resourceGroupServicePublish) {
								$resourceGroupServicePublish = $routeTableObjectArray.service.publish.resourceGroup | Where-Object { $_ -notlike '' }
							}
							if (!$resourceGroupServicePublish) {
								$resourceGroupServicePublish = $nsgObjectArray.service.publish.resourceGroup | Where-Object { $_ -notlike '' }
							}

							if (!$resourceGroupServicePublish) {
								Write-Error "Resource Group $($ResourceGroup.Name) doesn't exist and need to be created. Please provide Resource Group Service to Publish."
							}

							if ($resourceGroupServicePublish.count -gt 1) {
								[String]$resourceGroupServicePublishString = $resourceGroupServicePublish[0]
							}
							else {
								[String]$resourceGroupServicePublishString = $resourceGroupServicePublish
							}

							$createRG = $true

							$service = @{
								publish = @{
									resourceGroup = $resourceGroupServicePublishString
								}
							}
						}
						else {
							$RGlocation = $ifResourceGroupExists.location
							$createRG = $false
							$service = @{
								publish = @{
									resourceGroup = "none"
								}
							}
						}

						# Adding Objects to resourceGroup Object
						Write-Verbose "Adding '$($ResourceGroup.Name)' to Resource Group Object List"
						$ResourceGroupObject = @{
							resourceGroup         = @{
								name     = $ResourceGroup.Name;
								location = $RGlocation;
								service  = $service;
								createRG = $createRG;
							};
							vnets                 = $vnetObjectArray;
							routeTables           = $routeTableObjectArray;
							networkSecurityGroups = $nsgObjectArray
						}

						$resourceGroupObjectArray.Add($ResourceGroupObject) > $Null
						Write-Verbose "'$($ResourceGroup.Name)' Added"
					}
				}
			}

			# Code to Create Object from Yml
			if ($SettingsObject) {

				function createNetworkObjectFromYml {
					param (
						[string]
						$ymlObject,
						[string]
						$ObjectType,
						[Boolean]
						$hasGroups
					)

					if ($_.StartsWith('./')) {
						$interimPath = "$(Split-Path $SettingsFile)/$ymlObject.yml"
					}
					else {
						$interimPath = "$(Split-Path $SettingsFile)/$ObjectType/$ymlObject.yml"
					}

					try {
						$returnObject = Get-CmAzSettingsFile -Path $interimPath
					}
					catch {

						try {
							$interimPath.replace('/', '\')
							$returnObject = Get-CmAzSettingsFile -Path $interimPath
						}
						catch {
							throw "Not able to find file $ymlObject"
						}

					}

					if ($hasGroups) {

						ForEach ($object in $returnObject) {

							if ($ObjectType -eq "networkSecurityGroups") {
								$groupName = "ruleGroup"
								$childObject = "rules"
							}
							elseif ($ObjectType -eq "routeTables") {
								$groupName = "routeGroup"
								$childObject = "routes"
							}

							if ($object.$groupName) {

								$object.$groupName | ForEach-Object {

									try {
										$interimGroupPath = "$(Split-Path $interimPath)/groups/$_.yml"
										$returnObjectGroup = Get-CmAzSettingsFile -Path $interimGroupPath
									}
									catch [System.Management.Automation.RuntimeException] {

										try {
											$interimGroupPath.replace('/', '\')
											$returnObjectGroup = Get-CmAzSettingsFile -Path $interimGroupPath
										}
										catch {
											throw "Not able to find file at $interimGroupPath."
										}

									}

									$object.$childObject += $returnObjectGroup
								}

								$object.remove($groupName)
							}
						}
					}

					return $returnObject
				}

				$SettingsObject | ForEach-Object {
					$vnetObjectArray = [System.Collections.ArrayList]@()
					$routeTableObjectArray = [System.Collections.ArrayList]@()
					$nsgObjectArray = [System.Collections.ArrayList]@()

					$ResourceGroup = $_.ResourceGroupName

					$GlobalServiceContainer = $_

					# Set Vnet object
					if ($_.vnets) {

						$_.vnets | ForEach-Object {

							$vnetObjectYml = createNetworkObjectFromYml -ymlObject $_ -ObjectType "vnets" -hasGroups $false

							$vnetObjectYml.subnets | Where-Object { $_.networkSecurityGroup -like '' } | ForEach-Object {
								$_.networkSecurityGroup = ""
							}

							$vnetObjectYml.subnets | Where-Object { $_.routeTable -like '' } | ForEach-Object {
								$_.routeTable = ""
							}

							$vnetObjectYml | Where-Object { $_.location -like '' } | ForEach-Object {
								$_.location = ""
							}

							$vnetObjectYml | ForEach-Object {
								Set-GlobalServiceValues -GlobalServiceContainer $GlobalServiceContainer  -ServiceKey "vnet" -ResourceServiceContainer $_
							}

							$vnetObjectArray += $vnetObjectYml
							Write-Verbose "Vnets from $_ added to '$ResourceGroup'"
						}
					}

					# Set Route Table Object
					if ($_.routeTables) {

						$_.routeTables | ForEach-Object {

							$routeTableObjectYml = createNetworkObjectFromYml -ymlObject $_ -ObjectType "routeTables" -hasGroups $true

							$routeTableObjectYml | Where-Object { $_.location -like '' } | ForEach-Object {
								$_.location = ""
							}

							$routeTableObjectYml | ForEach-Object {
								Set-GlobalServiceValues -GlobalServiceContainer $GlobalServiceContainer -ServiceKey "routeTable" -ResourceServiceContainer $_
							}

							$routeTableObjectArray += $routeTableObjectYml
							Write-Verbose "Route tables from $_ added to '$ResourceGroup'"
						}
					}

					# Set network Security group Object
					if ($_.networkSecurityGroups) {

						$_.networkSecurityGroups | ForEach-Object {

							$nsgObjectYml = createNetworkObjectFromYml -ymlObject $_ -ObjectType "networkSecurityGroups" -hasGroups $true

							$nsgObjectYml | Where-Object { $_.location -like '' } | ForEach-Object {
								$_.location = ""
							}

							$nsgObjectYml | ForEach-Object {
								Set-GlobalServiceValues -GlobalServiceContainer $GlobalServiceContainer  -ServiceKey "networkSecurityGroup" -ResourceServiceContainer $_
							}

							$nsgObjectArray += $nsgObjectYml
							Write-Verbose "Network Security Groups from $_ added to '$ResourceGroup'"
						}
					}

					# Default values if required for ARM template sanity checks
					if (!$vnetObjectArray) {
						$vnetObjectArray = @(@{vnetName = "none"; location = ""; addressSpace = @("10.10.0.0/24"); subnets = @(@{subnetName = "none"; cidr = "0.0.0.0/0" }); service = @{publish = @{vnet = "" } } })
					}

					if (!$routeTableObjectArray) {
						$routeTableObjectArray = @(@{tableName = "none"; location = ""; routes = @(@{routeName = "none"; cidr = "0.0.0.0/0"; nextHopType = "VirtualAppliance"; nextHopIpAddress = "10.10.10.10" }); service = @{publish = @{routeTable = "" } } })
					}

					if (!$nsgObjectArray) {
						$nsgObjectArray = @(@{nsgName = "none"; location = ""; rules = @(@{ruleName = "none"; description = "none"; priority = "none"; direction = "none"; sourceIp = "10.10.10.10"; sourcePort = 3389; destinationIp = "10.10.10.11"; destinationPort = 3389; protocol = "Tcp"; Access = "allow" }); service = @{publish = @{networkSecurityGroup = "" } } })
					}

					# Build Resource Group Config
					$ifResourceGroupExists = Get-AzResourceGroup -Name $_.resourceGroupName -ErrorAction SilentlyContinue

					if (!$ifResourceGroupExists) {
						$RGlocation = $_.location

						if (!$RGlocation -and $vnetObjectArray[0].location ) {
							$RGlocation = $vnetObjectArray[0].location
						}

						if (!$RGlocation) {
							Write-Error "Resource Group doesnt exist and a location is also not provided to create one."
						}

						if (!$_.service.publish.resourceGroup) {
							Write-Error "Resource Group doesn't exist and need to be created. Please provide Resource Group Service to Publish."
						}

						$createRG = $true

						$service = @{
							publish = @{
								resourceGroup = $_.service.publish.resourceGroup
							}
						}
					}
					else {
						$RGlocation = $ifResourceGroupExists.location
						$createRG = $false
						$service = @{
							publish = @{
								resourceGroup = ""
							}
						}
					}

					# Adding Objects to resourceGroup Object
					Write-Verbose "Adding '$ResourceGroup' to Resource Group Object List"
					$ResourceGroupObject = @{
						resourceGroup         = @{
							name     = $ResourceGroup;
							location = $RGlocation;
							createRG = $createRG;
							service  = $service
						};
						vnets                 = $vnetObjectArray;
						routeTables           = $routeTableObjectArray;
						networkSecurityGroups = $nsgObjectArray
					}

					$resourceGroupObjectArray.Add($ResourceGroupObject) > $Null
					Write-Verbose "'$ResourceGroup' Added"
				}
			}

			# Arm Deployment
			Write-Verbose "Initiating deployment"

			New-AzDeployment `
				-Name "CmAz-Network-Deploy" `
				-TemplateFile $PSScriptRoot\New-CmAzIaasNetworking.json `
				-location $resourceGroupObjectArray[0].resourceGroup.location`
				-networkingArrayObject $resourceGroupObjectArray

			$resourceGroupsToSet = ($resourceGroupObjectArray.resourceGroup | where-object -Property createRG -eq $true).name

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceGroupIds $resourceGroupsToSet

			[System.Collections.ArrayList]$resourcesToSet = @()

			$resourcesToSet += $resourceGroupObjectArray.vnets.vnetName
			$resourcesToSet += $resourceGroupObjectArray.networkSecurityGroups.nsgName
			$resourcesToSet += $resourceGroupObjectArray.routeTables.tableName

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceIds $resourcesToSet

			Write-Verbose "Finished."
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem)
	}
}