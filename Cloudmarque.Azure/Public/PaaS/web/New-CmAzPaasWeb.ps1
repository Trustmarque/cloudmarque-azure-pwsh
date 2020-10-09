function New-CmAzPaasWeb {

	<#
		.Synopsis
		 Create an Frontdoor with backing webapps

		.Description
		 Completes following:
			* Creates Frontdoor
			* Creates Webapp and attaches to frontdoor
			* Optional API routing available

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 PaaS

		.Example
		 New-CmAzPaasWeb -SettingsFile ./web.yml

		.Example
		 New-CmAzPaasWeb -SettingsObject $settings
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

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Azure - Frontdoor | Backendpool | Webapps along with routing rules")) {

			if ($SettingsFile -and -not $SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (-not $SettingsFile -and -not $SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			$resourceGroupName = Get-CmAzResourceName -Resource "ResourceGroup" -Architecture "PaaS" -Region $SettingsObject.location -Name $SettingsObject.resourceGroupName
			$frontdoorName = Get-CmAzResourceName -Resource "FrontDoor" -Architecture "PaaS" -Region $SettingsObject.location -Name $SettingsObject.frontdoor.hostName
			$applicationInstrumentationKey = "none"

			if ($SettingsObject.monitoring.applicationInstrumentationKey) {
				$applicationInstrumentationKey = $SettingsObject.monitoring.applicationInstrumentationKey
			}

			$resourceGroupServiceTag = @{ "cm-service" = $SettingsObject.service.publish.resourceGroup }
			New-AzResourceGroup -ResourceGroupName $resourceGroupName -Location $SettingsObject.location -Tag $resourceGroupServiceTag -Force

			$frontdoorCheck = Get-AzFrontDoor -Name $frontdoorName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue

			if ($frontdoorCheck) {
				Write-Verbose "Frontdoor by the name $($frontdoorName) already exists."
				Remove-AzFrontDoor -Name $frontdoorName -ResourceGroupName $resourceGroupName
			}

			# Crawl across SettingsObject and create defined webapps
			$SettingsObject.AppServicePlans | ForEach-Object -Parallel {

				. "$using:PSScriptRoot/../../../Private/Tagging/Set-GlobalServiceValues.ps1"

				$threadSettingsObject = $using:SettingsObject
				$threadResourceGroupName = $using:resourceGroupName

				Set-GlobalServiceValues -GlobalServiceContainer $threadSettingsObject -ServiceKey "appServicePlan" -ResourceServiceContainer $_

				foreach ($app in $_.Webapps) {

					Write-Verbose "Initiating deployment of webapp : $($app.Name)"
					$_.Name = Get-CmAzResourceName -Resource "AppServicePlan" -Architecture "PaaS" -Region $_.Region -Name $_.Name
					$app.generatedName = Get-CmAzResourceName -Resource "WebApp" -Architecture "PaaS" -Region $_.Region -Name $app.Name

					Set-GlobalServiceValues -GlobalServiceContainer $threadSettingsObject -ServiceKey "webapp" -ResourceServiceContainer $app

					$app.service.publish.appServicePlan = $_.service.publish.appServicePlan

					$slots = @()

					if($app.Slots -Is [System.String]) {
						$slots = $app.slots | Select-Object { @{ Name = $_; }}
					}
					else {
						$slots = $app.slots
					}

					foreach ($slot in $slots) {
						Set-GlobalServiceValues -GlobalServiceContainer $threadSettingsObject -ServiceKey "slot" -ResourceServiceContainer $slot
					}

					New-AzResourceGroupDeployment  `
						-Name $app.generatedName `
						-ResourceGroupName $threadResourceGroupName `
						-TemplateFile "$using:PSScriptRoot\New-CmAzPaasWeb.json" `
						-WebAppName $app.generatedName `
						-Kind "linux" `
						-LinuxFxVersion $app.Runtime `
						-AppServicePlanName $_.Name `
						-Sku $_.Sku `
						-Location $_.region `
						-SlotNames $slots `
						-AppInstrumatationKey $using:applicationInstrumentationKey `
						-ServiceContainer $app.service.publish `
						-Force

					if ($app.contentDeliveryNetwork.profileName -And $app.contentDeliveryNetwork.endpointName) {

						$app.contentDeliveryNetwork.profileName = Get-CmAzResourceName -Resource "CdnProfile" -Architecture "PaaS" -Region $_.region -Name $app.contentDeliveryNetwork.profileName
						$app.contentDeliveryNetwork.endpointName = Get-CmAzResourceName -Resource "Endpoint" -Architecture "PaaS" -Region $_.region -Name $app.contentDeliveryNetwork.endpointName

						Write-Verbose "Resource type identified to be : $($resourceType)"
		
						$webApp = Get-AzWebApp -ResourceGroupName $threadResourceGroupName -Name $app.generatedName -ErrorAction SilentlyContinue

						if ($webApp) {
							$domain = ($webApp).DefaultHostName
						}
						else {
							Write-Verbose "$($app.generatedName) not found."
						}

						Set-GlobalServiceValues -GlobalServiceContainer $threadSettingsObject -ServiceKey "cdn" -ResourceServiceContainer $app.contentDeliveryNetwork
						Set-GlobalServiceValues -GlobalServiceContainer $threadSettingsObject -ServiceKey "endpoint" -ResourceServiceContainer $app.contentDeliveryNetwork

						if (!(Get-AzCdnProfile -ProfileName $app.contentDeliveryNetwork.profileName)) {
							New-AzCdnProfile `
							-ProfileName $app.contentDeliveryNetwork.profileName `
							-ResourceGroupName $threadResourceGroupName `
							-Sku $app.contentDeliveryNetwork.Sku `
							-Location $_.region `
							-Tag @{ "cm-service" = $app.contentDeliveryNetwork.service.publish.cdn }
						}

						if (!(Get-AzCdnEndpoint -ProfileName $app.contentDeliveryNetwork.profileName -ResourceGroupName $threadResourceGroupName)) {
							New-AzCdnEndpoint `
								-EndpointName $app.contentDeliveryNetwork.endpointName `
								-ProfileName $app.contentDeliveryNetwork.profileName `
								-Location $_.region `
								-ResourceGroupName $threadResourceGroupName `
								-OriginName $app.generatedName `
								-OriginHostName $domain `
								-Tag @{ "cm-service" = $app.contentDeliveryNetwork.service.publish.endpoint }
						}
					}

					Write-Verbose "$($app.Name) is created"
				}
			}

			#  Create FrontendEndpoint Object
			$SettingsObject.ApiManagementServices | ForEach-Object -Parallel {

				if (!$_.Name -or !$_.Region -or !$_.Organization -or !$_.AdminEmail -or !$_.Sku ) {
					Continue
				}

				. "$using:PSScriptRoot/../../../Private/Tagging/Set-GlobalServiceValues.ps1"

				Set-GlobalServiceValues -GlobalServiceContainer $using:SettingsObject -ServiceKey "apiManagement" -ResourceServiceContainer $_

				$threadResourceGroupName = $using:resourceGroupName

				try {

					$_.Name = Get-CmAzResourceName -Resource "APImanagementServiceInstance" -Architecture "PaaS" -Region $_.Region -Name $_.Name

					Write-Verbose "Creating ApiManagementService $($_.Name)"

					$apiManagementServiceTag = New-Object "System.Collections.Generic.Dictionary``2[System.String,System.String]"
					$apiManagementServiceTag.Add("cm-service", $_.service.publish.apiManagement)

					New-AzApiManagement `
						-ResourceGroupName $threadResourceGroupName `
						-Location $_.Region `
						-Name $_.Name `
						-Organization $_.Organization `
						-AdminEmail $_.AdminEmail `
						-Sku $_.Sku `
						-Tag $apiManagementServiceTag

					while (!(([system.uri](Get-AzApiManagement -Name $_.Name -ResourceGroupName $threadResourceGroupName).RuntimeUrl).Host)) {
						Start-Sleep -minutes 5
						Write-Verbose "Waiting for API To generate URL....."
					}
				}
				catch {
					Write-Warning "An error occurred, The API service is potentially already present $PSItem"
				}

				$url = ([system.uri](Get-AzApiManagement -Name $_.Name -ResourceGroupName $threadResourceGroupName).RuntimeUrl).Host
				Write-Verbose "Api url: $($url)"
			}

			function CustomDomainOnFrontDoorEnableHttps {
				param(
					$vaultName,
					$domainName,
					$secretName,
					$resourceGroupName,
					$frontdoorName
				)

				if (!$vaultName) {

					Enable-AzFrontDoorCustomDomainHttps `
						-ResourceGroupName $resourceGroupName `
						-FrontDoorName $frontdoorName `
						-FrontendEndpointName ($frontendEndpointObjectArray | Where-Object Hostname -eq $domainName).Name `
						-MinimumTlsVersion "1.2"
				}
				else {
					Enable-AzFrontDoorCustomDomainHttps `
						-ResourceGroupName $resourceGroupName `
						-FrontDoorName $frontdoorName `
						-FrontendEndpointName ($frontendEndpointObjectArray | Where-Object Hostname -eq $domainName).Name `
						-Vault (Get-AzKeyVault -VaultName $vaultName).ResourceId `
						-SecretName $secretName `
						-SecretVersion (Get-AzKeyVaultSecret -VaultName kvaultcorerg -Name $secretName).Version `
						-MinimumTlsVersion "1.0"
				}
			}

			$frontendEndpointObjectArray = [System.Collections.ArrayList]@()

			function SetFrontendEndpointObject {
				param (
					$domainName,
					$sessionAffinity,
					$webApplicationFirewallPolicy,
					$name
				)

				if ($sessionAffinity) {
					$sessionAffinity = "Enabled"
				}
				else {
					$sessionAffinity = "Disabled"
				}

				Write-Verbose "Initiating creation of frontend endpoint object.."
				if ($SettingsObject.frontDoor.webApplicationFirewallPolicy) {

					$frontendEndpointObject = New-AzFrontDoorFrontendEndpointObject `
						-Name $name `
						-HostName $domainName `
						-SessionAffinityEnabledState $sessionAffinity `
						-WebApplicationFirewallPolicyLink $webApplicationFirewallPolicy
				}
				else {

					$frontendEndpointObject = New-AzFrontDoorFrontendEndpointObject `
						-Name $name `
						-HostName $domainName `
						-SessionAffinityEnabledState $sessionAffinity
				}

				$frontendEndpointObject
			}

			$frontendEndpointObjectMain = SetFrontendEndpointObject `
					-Name $frontdoorName `
					-DomainName "$frontdoorName.azurefd.net" `
					-SessionAffinity $SettingsObject.frontDoor.sessionAffinity `
					-WebApplicationFirewallPolicy $SettingsObject.frontDoor.webApplicationFirewallPolicy

			$frontendEndpointObjectArray.add($frontendEndpointObjectMain) > $null

			Write-Verbose "Frontend Local Hostname:"
			$frontendEndpointObjectMain | Write-Verbose

			if ($SettingsObject.frontDoor.customDomains.domainName) {

				foreach ($domain in $SettingsObject.frontDoor.customDomains) {

					Write-Verbose "Adding $($domain.domainName) Object"

					$name = (Get-CmAzResourceName -Resource "frontDoor" -Architecture "Core" -Region $SettingsObject.location -Name "frontendCustomObject")

					$frontendEndpointObjectCustom = SetFrontendEndpointObject `
						-Name $name `
						-Domain $domain.domainName `
						-SessionAffinity $domain.sessionAffinity `
						-WebApplicationFirewallPolicy $domain.webApplicationFirewallPolicy

					$frontendEndpointObjectArray.add($frontendEndpointObjectCustom) > $null
				}

				$frontendEndpointObjectArray
			}

			# Create Back end pool Object
			Write-Verbose "Initiating creation of Backend Pool"
			$backEndPoolObjectArray = [System.Collections.ArrayList]@()
			$healthProbeSettingObjectArray = [System.Collections.ArrayList]@()
			$loadBalancingSettingObjectArray = [System.Collections.ArrayList]@()
			$routingRuleObjectArray = [System.Collections.ArrayList]@()

			foreach ($backEndPool in $SettingsObject.frontDoor.backEndPools) {

				$backendObjectArray = [System.Collections.ArrayList]@()

				$SettingsObject.appServicePlans.webapps | Where-Object { $_.backendpool -match $backEndPool.Name } | ForEach-Object {

					$backEndDomainName = (Get-AzWebApp -ResourceGroupName $resourceGroupName -Name $_.generatedName).DefaultHostName

					$backendHostHeader = $backEndDomainName

					if ($_.backendHostHeader -eq $false) {
						$backendHostHeader = ""
					}

					$backEndObject = New-AzFrontDoorBackendObject -Address $backEndDomainName -BackendHostHeader $backendHostHeader
					$backendObjectArray.Add($backEndObject) > $null
				}

				$SettingsObject.ApiManagementServices | Where-Object { $_.backendPool -eq $backEndPool.Name } | ForEach-Object {

					$backEndDomainName = ([system.uri](Get-AzApiManagement -ResourceGroupName $resourceGroupName -Name $_.name).RuntimeUrl).Host

					$backendHostHeader = $backEndDomainName

					if ($_.backendHostHeader -eq $false) {
						$backendHostHeader = ""
					}

					$backEndObject = New-AzFrontDoorBackendObject -Address $backEndDomainName -BackendHostHeader $backendHostHeader
					$backendObjectArray.Add($backEndObject) > $null
				}

				if (!$backEndPool.healthCheckPath) {
					$backEndPool.healthCheckPath = "/index.html"
				}

				if (!$backEndPool.protocol) {
					$backEndPool.protocol = "Https"
				}
				elseif($backEndPool.protocol -ne "Https" -and $backEndPool.protocol -ne "Http") {
					Write-Error "Invalid backend pool protocol." -Category InvalidArgument -CategoryTargetName "SettingsObject.frontdoor.backendPools.protocol"
				}

				$healthProbeSettingObject = New-AzFrontDoorHealthProbeSettingObject -Name "HealthProbeSetting-$($backEndPool.Name)" -Path  $backEndPool.HealthCheckPath -Protocol $backEndPool.protocol
				$loadBalancingSettingObject = New-AzFrontDoorLoadBalancingSettingObject -Name "Loadbalancingsetting-$($backEndPool.Name)"

				$backEndPoolObject = New-AzFrontDoorBackendPoolObject -Name $backEndPool.Name `
					-FrontDoorName $frontdoorName `
					-ResourceGroupName $resourceGroupName `
					-Backend $backendObjectArray `
					-HealthProbeSettingsName "HealthProbeSetting-$($backEndPool.Name)" `
					-LoadBalancingSettingsName "Loadbalancingsetting-$($backEndPool.Name)"

				Write-Verbose "Backend Pool Object Created for $($backEndPool.Name)"

				$backEndPoolObjectArray.Add($backEndPoolObject) > $null
				$healthProbeSettingObjectArray.Add($healthProbeSettingObject) > $null
				$loadBalancingSettingObjectArray.Add($loadBalancingSettingObject) > $null
			}

			foreach ($rule in $SettingsObject.frontDoor.rules) {

				$backendPool = $SettingsObject.frontDoor.backEndPools | Where-Object { $_.Name -eq $rule.backendPoolName } | Select-Object -First 1

				if(!$backEndPool) {
					Write-Error "Backend pool $($rule.backendPoolName) does not exist" -Category InvalidArgument -CategoryTargetName "SettingsObject.frontdoor.rules.backendPoolName"
				}

				foreach ($endpointObject in $frontendEndpointObjectArray) {

					$routingRuleObject = New-AzFrontDoorRoutingRuleObject `
						-Name $rule.Name `
						-FrontDoorName $frontdoorName `
						-ResourceGroupName $resourceGroupName `
						-FrontendEndpointName $endpointObject.Name `
						-BackendPoolName  $backendPool.Name `
						-PatternToMatch  $rule.Pattern
				}

				$routingRuleObjectArray.Add($routingRuleObject) > $null
			}

			# Create Frontdoor
			Write-Verbose "Initiating creation of Azure frontdoor"
			New-AzFrontDoor `
				-Name $frontdoorName `
				-ResourceGroupName $resourceGroupName `
				-FrontendEndpoint $frontendEndpointObjectArray `
				-BackendPool $backEndPoolObjectArray `
				-HealthProbeSetting $healthProbeSettingObjectArray `
				-LoadBalancingSetting $loadBalancingSettingObjectArray `
				-RoutingRule $routingRuleObjectArray `
				-Tag @{ "cm-service" = $SettingsObject.service.publish.frontdoor }

			if ($SettingsObject.frontDoor.customDomains.domainName) {

				foreach ($domain in $SettingsObject.frontDoor.customDomains) {

					$enableHttps = CustomDomainOnFrontDoorEnableHttps `
						-DomainName $domain.domainName  `
						-VaultName $domain.customCertificateVaultName  `
						-SecretName $domain.customCertificateSecretName  `
						-ResourceGroupName $resourceGroupName `
						-FrontDoorName $frontdoorName

					$enableHttps | Write-Verbose
				}
			}

			Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceGroupIds $resourceGroupName

			Write-Verbose "Finished!"
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSitem);
	}
}