function New-CmAzCoreAutomation {

	<#
		.Synopsis
		 Create an Automation account with runbooks.

		.Description
		 Completes the following:
			* Creates Resource Group for runbook, dsc or both.
			* Creates Automation account for runbook, dsc or both.
			* Creates Key vault certificate if not available.
			* Create RunAsAccount and RunAsCertificate for Automation accounts.
			* Optionally sync code repository (tvfc | git | github).

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 New-CmAzCoreAutomation -SettingsFile "c:/directory/settingsFile.yml"

		.Example
		 New-CmAzCoreAutomation -SettingsObject $settings
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

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Cloudmarque Core Automation Stack")) {

			# Initializing settings file values

			$azSubscription = Get-AzSubscription
			$projectContext = Get-CmAzContext -RequireAzure -ThrowIfUnavailable

			if ($SettingsFile -and !$SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (!$SettingsFile -and !$SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			foreach ($item in $SettingsObject.Automation.Keys) {

				$randomValue = Get-Random -Minimum 1001 -Maximum 9999

				# Set Account Type
				if ($item -eq "dsc") {
					$accountType = "dsc"
				}
				elseif ($item -eq "runbook") {
					$accountType = "runbook"
				}
				else {
					Write-Error "Set type to be either runbook or dsc."
				}

				Write-Verbose "Setting location set to $($SettingsObject.Location)..."
				$location = $SettingsObject.Location

				Write-Verbose "Creating automation account for $accountType..."
				if (!$location) {
					Write-Error "Location not found."
				}

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "keyvault" -ResourceServiceContainer $SettingsObject.Automation.$accountType -IsDependency

				$keyVault = Get-CmAzService -Service $SettingsObject.Automation.$accountType.service.dependencies.keyvault -Region $SettingsObject.location -ThrowIfUnavailable

				$certificateName = $SettingsObject.Automation.$accountType.CertificateName
				
				if (!$certificateName) {
					Write-Verbose "No KeyVault Certificate provided, a new certificate will be created..."
					$certificateName = $SettingsObject.Automation.$accountType.CertificateName
				}

				$keyVaultCertificatePasswordSecretName = $SettingsObject.Automation.$accountType.keyVaultCertificatePasswordSecretName
				
				if (!$keyVaultCertificatePasswordSecretName) {
					Write-Error "No keyVault path or Password provided for Certificate..."
					break
				}

				if ($SettingsObject.Automation.$accountType.sourceControl.url) {

					$repoUrl = $SettingsObject.Automation.$accountType.sourceControl.url
					$repoType = $SettingsObject.Automation.$accountType.sourceControl.type
					$folderPath = $SettingsObject.Automation.$accountType.sourceControl.folderPath
					$keyVaultPersonalAccessToken = $SettingsObject.Automation.$accountType.sourceControl.keyVaultPersonalAccessToken
					$branch = $SettingsObject.Automation.$accountType.sourceControl.branch

					if (!$keyVaultPersonalAccessToken) {
						Write-Error "No keyVault path or Password provided for Personal Access Token."
						break
					}

					if (!$branch) {
						$branch = "master"
					}

					if (!$repoType) {
						$repoType = "github"
					}
					
					$repoType = $repoType.ToLower()
					if (!$folderPath) {
						$folderPath = "/"
					}

					$personalAccessToken = (Get-AzKeyVaultSecret -VaultName $keyVault.name -Name $keyVaultPersonalAccessToken).SecretValue
					if (!$personalAccessToken) {
						Write-Error "No PAT found on key vault."
					}

					Write-Verbose "Repository settings are found to be ok, SCM integration will be attempted..."
				}
				else {
					Write-Verbose "No Repository provided $accountType, SCM Intergration will be skipped..."
				}

				Write-Verbose "Creating Resource Group..."
				$nameResourceGroup = Get-CmAzResourceName -Resource "ResourceGroup" -Architecture "Core" -Region $location -Name $SettingsObject.name
				$resourceGroupServiceTag = @{ "cm-service" = $SettingsObject.service.publish.resourceGroup }
				$resourceGroup = New-AzResourceGroup -ResourceGroupName $nameResourceGroup -Location $location -Tag $resourceGroupServiceTag -Force

				Write-Verbose "Creating Automation Account..."
				$automationAccountName = Get-CmAzResourceName -Resource "Automation" -Architecture "Core" -Region $location -Name $SettingsObject.name

				# Create Automation account
				New-AzResourceGroupDeployment `
					-ResourceGroupName $nameResourceGroup `
					-TemplateFile "$PSScriptRoot\New-CmAzCoreAutomation.json" `
					-AccountName $automationAccountName `
					-Location $location `
					-AutomationService $SettingsObject.service.publish.automation `
					-Force

				function KeyVaultSelfSignedCert {
					param (
						$keyVault,
						$CertificateName,
						$SubjectName,
						$ValidityInMonths,
						$RenewDaysBefore
					)

					Write-Verbose "Starting Certificate Generation..."

					$policy = New-AzKeyVaultCertificatePolicy `
						-SubjectName $SubjectName `
						-ReuseKeyOnRenewal `
						-IssuerName 'Self' `
						-ValidityInMonths $ValidityInMonths `
						-RenewAtNumberOfDaysBeforeExpiry $RenewDaysBefore

					$keyVaultCertificate = Add-AzKeyVaultCertificate `
						-VaultName $keyVault `
						-CertificatePolicy $policy `
						-Name $CertificateName

					while ( $keyVaultCertificate.Status -ne "completed") {
						Start-Sleep -Seconds 1
						$keyVaultCertificate = Get-AzKeyVaultCertificateOperation -VaultName $keyVault -Name $CertificateName
					}

					(Get-AzKeyVaultCertificate -VaultName $keyVault -Name $CertificateName).Certificate
				}

				function CreateServicePrincipal {
					param (
						[System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate,
						[string] $applicationDisplayName
					)

					Write-Verbose "Fetch Certificate Data from Keyvault..."
					$pfxCert = [Convert]::ToBase64String($Certificate.GetRawCertData())
					
					$application = Get-AzADApplication -DisplayName $applicationDisplayName -ErrorAction SilentlyContinue
					if (!$application)	{
						Write-Verbose "Application not found. Creating new application..."
						$application = New-AzADApplication -DisplayName $applicationDisplayName -HomePage ("http://" + $applicationDisplayName) -IdentifierUris ("http://" + $randomValue)
					}

					#Needs Application administrator or GLOBAL ADMIN"
					Write-Verbose "Creating Application Credential..."
					New-AzADAppCredential -ApplicationId $application.ApplicationId -CertValue $pfxCert -StartDate $Certificate.NotBefore -EndDate $Certificate.NotAfter
					
					Write-Verbose "Checking for existing service principal..."
					$servicePrincipal = Get-AzADServicePrincipal -ApplicationId $application.ApplicationId
					if(!$servicePrincipal)	{
						
						while (!$servicePrincipal)	{
							Write-Verbose "Trying to create new service principal..."
							New-AzADServicePrincipal -ApplicationId $application.ApplicationId
							$servicePrincipal = Get-AzADServicePrincipal -ApplicationId $application.ApplicationId
						}
					}
					else {
						Write-Verbose "Service principal found..."
					}

					# Requires User Access Administrator or Owner.
					Write-Verbose "Fetching Role Assignment..."
					$getRole = Get-AzRoleAssignment -ServicePrincipalName $application.ApplicationId -ErrorAction SilentlyContinue
					if (!$getRole) {

						Write-Verbose "Role Assignment doesnt exist. Creating new Role Assignment..."
						$newRole = New-AzRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $application.ApplicationId -ErrorAction SilentlyContinue

						$retries = 0;

						While (!$newRole -and $retries -le 6) {
							Start-Sleep -s 10
							New-AzRoleAssignment -RoleDefinitionName Contributor -ServicePrincipalName $application.ApplicationId | Write-Verbose -ErrorAction SilentlyContinue
							$newRole = Get-AzRoleAssignment -ServicePrincipalName $application.ApplicationId -ErrorAction SilentlyContinue
							$retries++;
						}

						Write-Verbose "Contributer role assigned to Service Principal $($application.ApplicationId)..."
					}
					else {
						Write-Verbose "Role Assignment Already Present..."
						Write-Verbose $getRole
					}

					return $application;
				}
				
				function CreateAutomationCertificateAsset {
					param (
						$certificateName
					)

					Write-Verbose "Trying to Pull Certificate Password from KeyVault..."
					$certificatePassword = Get-AzKeyVaultSecret -VaultName $keyVault.name -Name $keyVaultCertificatePasswordSecretName

					Write-Verbose "Trying to Pull Certificate from KeyVault..."
					$pfxFileByte = [System.Convert]::FromBase64String((Get-AzKeyVaultSecret -VaultName $keyVault.name -Name $certificateName).SecretValueText)
					$pfxCertPathForRunAsAccount = Join-Path  -Path $($projectContext.ProjectRoot) ($CertificateName + ".pfx")

					# Write to a file
					$certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
					$certCollection.Import($pfxFileByte, "", [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

					#Export the .pfx file
					$protectedCertificateBytes = $certCollection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $certificatePassword.SecretValueText)
					[System.IO.File]::WriteAllBytes($PfxCertPathForRunAsAccount, $protectedCertificateBytes)

					Write-Verbose "Creating Automation Certificate Asset..."
					Remove-AzAutomationCertificate -ResourceGroupName $nameResourceGroup -AutomationAccountName  $automationAccountName -Name "AzureRunAsCertificate" -ErrorAction SilentlyContinue
					New-AzAutomationCertificate -ResourceGroupName $nameResourceGroup -AutomationAccountName  $automationAccountName -Path $pfxCertPathForRunAsAccount  -Name "AzureRunAsCertificate" -Password $certificatePassword.SecretValue -Exportable

					@{
						"certificatePath" = $PfxCertPathForRunAsAccount;
						"password"        = $certificatePassword.SecretValueText
					}
				}

				function CreateAutomationConnectionAsset {
					param (
						[string] $ResourceGroup,
						[string] $AutomationAccountName,
						[string] $ConnectionAssetName,
						[string] $ConnectionTypeName,
						[System.Collections.Hashtable] $ConnectionFieldValues
					)
					
					Write-Verbose "Creating Automation Connection Asset..."
					Remove-AzAutomationConnection -ResourceGroupName $ResourceGroup -AutomationAccountName  $AutomationAccountName -Name $ConnectionAssetName -Force -ErrorAction SilentlyContinue
					New-AzAutomationConnection -ResourceGroupName $ResourceGroup -AutomationAccountName  $AutomationAccountName -Name $ConnectionAssetName -ConnectionTypeName $ConnectionTypeName -ConnectionFieldValues $ConnectionFieldValues
				}

				[string]$applicationDisplayName = "AutomationAppAccount-$automationAccountName"

				Write-Verbose "Fetching Certificate from Keyvault..."
				$keyVaultSelfSignedCert = (Get-AzKeyVaultCertificate -VaultName $keyVault.name -Name $certificateName).Certificate

				Write-Verbose "Create New Certificate using keyvault if it doesn't exist..."
				if (!$keyVaultSelfSignedCert) {
					try {
						Write-Verbose "Creating new certificate in keyvault: $($keyVault.name)..."
						$keyVaultSelfSignedCert = KeyVaultSelfSignedCert  `
							-KeyVault $keyVault.name `
							-CertificateName $certificateName `
							-SubjectName "CN=$certificateName" `
							-ValidityInMonths 12 `
							-RenewDaysBefore 30
						
						Write-Verbose "Certificate generated $certificateName : $($keyVaultSelfSignedCert.Thumbprint)..."
						$keyVaultSelfSignedCert = (Get-AzKeyVaultCertificate -VaultName $keyVault.name -Name $certificateName).Certificate
					}
					catch {
						Write-Error "Certificate Generation failed."
						break
					}
				}
				else {
					Write-Verbose "Certificate found $certificateName : $($keyVaultSelfSignedCert.Thumbprint)..."
				}

				# Creates Automation Certificate
				$certificateValues = CreateAutomationCertificateAsset -CertificateName $certificateName
				$keyVaultSelfSignedPfxCert = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @($certificateValues.certificatePath , $certificateValues.password)

				Write-Verbose "Creating Service Principal..."
				$servicePrincipal = CreateServicePrincipal -Certificate $keyVaultSelfSignedPfxCert -ApplicationDisplayName $applicationDisplayName

				Write-Verbose "Populating ConnectionFieldValues..."
				$connectionFieldValues = @{ 
					"ApplicationId" = $servicePrincipal.ApplicationId.ToString(); 
					"TenantId" = $azSubscription.TenantId; 
					"CertificateThumbprint" = $keyVaultSelfSignedPfxCert.Thumbprint; 
					"SubscriptionId" = $azSubscription.SubscriptionId 
				}

				Write-Verbose "Create an Automation connection asset named AzureRunAsConnection in the Automation account. This connection uses the service principal."
				CreateAutomationConnectionAsset -ResourceGroup $nameResourceGroup -AutomationAccountName $automationAccountName -ConnectionAssetName "AzureRunAsConnection" -ConnectionTypeName "AzureServicePrincipal" -ConnectionFieldValues $connectionFieldValues

				if ($repoUrl) {
					try {
						if ($repoType -eq "tvfc") {
							New-AzAutomationSourceControl -Name "$repoType-$randomValue" -RepoUrl $repoUrl -SourceType VsoTfvc -AccessToken $personalAccessToken -ResourceGroupName $nameResourceGroup -AutomationAccountName $automationAccountName -FolderPath $folderPath
						}
						elseif ($repoType -eq "github") {
							New-AzAutomationSourceControl -Name "$repoType-$randomValue" -RepoUrl $repoUrl -SourceType GitHub -AccessToken $personalAccessToken -Branch $branch -ResourceGroupName $nameResourceGroup -AutomationAccountName $automationAccountName -FolderPath $folderPath
						}
						elseif ($repoType -eq "git") {
							New-AzAutomationSourceControl -Name "$repoType-$randomValue" -RepoUrl $repoUrl -SourceType VsoGit -AccessToken $personalAccessToken -Branch $branch -ResourceGroupName $nameResourceGroup -AutomationAccountName $automationAccountName -FolderPath $folderPath
						}
						else {
							Write-Warning "Please choose correct repository - tvfc | git | github." -ErrorAction Continue
						}

						Write-Verbose "$repoType Added..."

						# Attempt autosync
						try {
							Update-AzAutomationSourceControl -AutomationAccountName $automationAccountName -Name "$repoType-$randomValue" -AutoSync $true -ResourceGroupName $nameResourceGroup
						}
						catch {
							$_.ToString() | Write-Verbose
							Write-Warning "AutoSync couldn't be enabled. Make sure you have 'Read, query, manage' permissions" -ErrorAction Continue -WarningAction Continue
						}

						# Start first sync job
						Start-AzAutomationSourceControlSyncJob -AutomationAccountName $automationAccountName -Name "$repoType-$randomValue" -ResourceGroupName $nameResourceGroup
						Write-Verbose "First Sync initiated..."
					}
					catch {
						Write-Verbose "Repository couldn't be added..."
						Write-Verbose "$PSitem..."
					}
				}
				
				Set-DeployedResourceTags -TagSettingsFile $TagSettingsFile -ResourceGroupIds $nameResourceGroup
			}

			Write-Verbose "Finished!"
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSitem);
	}
}
