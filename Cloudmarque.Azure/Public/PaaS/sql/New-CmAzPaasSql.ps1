function New-CmAzPaasSql {

	<#
		.Synopsis
		 Create SQL databases

		.Description
		 Completes following:
			* Creates SQL Server.
			* Creates databases.
			* Configures firewall (for postgres | mariaDB | mysql)
			* Enable log analytics (Optional)

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 PaaS

		.Example
		 New-CmAzPaasSql -SettingsFile ./sql.yml

		.Example
		 New-CmAzPaasSql -SettingsObject $settings
	#>

	[OutputType([System.Collections.ArrayList])]
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

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy SQL database")) {

			if ($SettingsFile -and -not $SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (-not $SettingsFile -and -not $SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			$resourceGroup = Get-CmAzService -Service $SettingsObject.service.dependencies.resourceGroup -IsResourceGroup -ThrowIfUnavailable -ThrowIfMultiple

			if (!$SettingsObject.service.dependencies.workspace) {
				$workspace = @{"Name" = ""; "ResourceId" = ""; "Location" = "" }
			}
			else {
				Write-Verbose "Fetching workspace.."
				$workspace = Get-CmAzService -Service $SettingsObject.service.dependencies.workspace -ThrowIfUnavailable -ThrowIfMultiple
			}

			if (!$SettingsObject.logRetentionPeriodInDays) {
				$logRetentionPeriodInDays = 30
			}
			else {
				$logRetentionPeriodInDays = $SettingsObject.logRetentionPeriodInDays
			}

			[system.Collections.ArrayList]$sqlObjectArray = @()
			[system.Collections.ArrayList]$sqlObjectArraySharedServer = @()
			[system.Collections.ArrayList]$resourcesToSet = @()
			[system.Collections.ArrayList]$UniqueSqlServerNames = @()

			Write-Verbose "Starting to build object for deployment.."

			$SettingsObject.sqlConfig | ForEach-Object {

				[System.Collections.ArrayList] $databaseCollection = @()

				Write-Verbose "Working on $($_.serverName)"
				if ($_.databases) {

					foreach ($database in $_.databases) {

						if ($database -is [string]) {
							$databaseObject = @{
								"name" = Get-CmAzResourceName -Resource "AzureSQLDatabase" -Architecture "PaaS" -Region $SettingsObject.Location -Name $database
							}
							Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "database" -ResourceServiceContainer $databaseObject
							$databaseCollection.Add($databaseObject) > $Null
						}

						if ($database -is [Hashtable]) {
							$database.name = Get-CmAzResourceName -Resource "AzureSQLDatabase" -Architecture "PaaS" -Region $SettingsObject.Location -Name $database.name
							Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "database" -ResourceServiceContainer $database
							$databaseCollection.Add($database) > $Null
						}
					}
				}
				else {
					$databaseObject = @{
						"name" = Get-CmAzResourceName -Resource "AzureSQLDatabase" -Architecture "PaaS" -Region $SettingsObject.Location -Name $_.serverName;
					}
					Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "database" -ResourceServiceContainer $databaseObject
					$databaseCollection.Add($databaseObject) > $Null
				}

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "keyvault" -ResourceServiceContainer $_ -IsDependency
				$keyVault = Get-CmAzService -Service $SettingsObject.service.dependencies.keyvault -ThrowIfUnavailable -ThrowIfMultiple

				$serverName = Get-CmAzResourceName -Resource "AzureSQLDatabaseserver" -Architecture "PaaS" -Region $SettingsObject.Location -Name $_.serverName

				if ($UniqueSqlServerNames -contains $_.serverName) {
					$sharedServer = $true
				}
				else {
					$sharedServer = $false
					$UniqueSqlServerNames.add($_.serverName) > $Null
				}

				$dbFamily = switch ($_.family) {

					azuresql {
						"Microsoft.Sql"
					}
					postgressql {
						"Microsoft.DBforPostgreSQL"
					}
					mariadb {
						"Microsoft.DBforMariaDB"
					}
					mysql {
						"Microsoft.DBforMySQL"
					}
					default { Write-Error "Please provide correct database family name. Choose from azuresql|postgressql|mariadb|mysql" }
				}

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "server" -ResourceServiceContainer $_
				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "elasticPool" -ResourceServiceContainer $_

				if (!$_.firewallRules) {
					$_.firewallRules = @(@{
						"startIpAddress" = "0.0.0.0";
						"endIpAddress"   = "255.255.255.255"
					})
				}

				$elasticPool = "none"

				if (!$_.type) {
					$_.type = "none"
				}elseif ($_.type -eq "elasticPool") {
					$elasticPool = 	Get-CmAzResourceName -Resource "AzureSQLElasticPool" -Architecture "PaaS" -Region $SettingsObject.Location -Name $_.elasticPoolName
				}

				$sqlObject = @{
					"data"                       = @{
						"family"                = $dbFamily
						"sharedServer"          = $sharedServer
						"type"                  = ($_.type).Tolower()
						"serverName"            = $serverName;
						"service"				= $_.service;
						"databases"             = $databaseCollection;
						"sku"                   = $_.sku;
						"version"               = $_version;
						"elasticPoolProperties" = @{
							"collation"                     = "SQL_Latin1_General_CP1_CI_AS";
							"requestedServiceObjectiveName" = "ElasticPool";
							"elasticPoolName"               = $elasticPool;
						};
						"administratorLogin"    = $_.administratorLogin;
						"workspace"             = $workspace;
						"logRetentionDays"      = $logRetentionPeriodInDays;
						"firewallRules"         = $_.firewallRules
					};

					"administratorLoginPassword" = @{
						"keyVaultid" = $keyVault.resourceId;
						"secretName" = $_.passwordSecretName
					}
				}

				if ($sqlObject.data.sharedServer) {
					($sqlObjectArraySharedServer).Add($sqlObject) > $Null
				}
				else {
					($sqlObjectArray).Add($sqlObject) > $Null
				}

			}

			$allsqlObjectArray = @($sqlObjectArray, $sqlObjectArraySharedServer)

			$allsqlObjectArray | ForEach-Object {

				if ($_) {

					switch ($_.data.sharedServer[0]) {
						"true" {
							$templateType = "Shared"
						}
						default {
							$templateType = "Parent"
						}
					}

					New-AzResourceGroupDeployment `
						-Name "Cm_SQL_$templateType" `
						-ResourceGroupName $resourceGroup.ResourceGroupName `
						-TemplateFile "$PSScriptRoot\New-CmAzPaasSql.json" `
						-SqlObjectArray $_ `
						-Location $SettingsObject.Location `
						-Force
				}
			}

			$resourcesToSet += ($allsqlObjectArray.data | where-object -Property family -eq 'Microsoft.Sql').databases.name
			$resourcesToSet += ($allsqlObjectArray.data | where-object -Property type -eq 'elasticPool').elasticPoolProperties.elasticPoolName
			$resourcesToSet += $allsqlObjectArray.data.serverName

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceIds $resourcesToSet

			Write-Verbose "Finished."
	    }
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSitem);
	}
}
