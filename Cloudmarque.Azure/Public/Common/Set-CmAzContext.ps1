function Set-CmAzContext {

	<#
		.Synopsis
		 Sets the session context for subsequent session runs.

    	.Description
     	 Sets the following in an globally accessible context:
      		* Environment
      		* Project root directory
      		* Build number
      		* Package name
      		* Package version
      		* Build repo name
      		* Build definition name
      		* Build definiton number
      		* Date

    	.Parameter Environment
     	 The environment in which the context is set, e.g prd, dev etc

   		.Parameter ProjectRoot
     	 Where settings and resource files are created.

    	.Parameter ProjectConfirmation
     	 Override for prompt to create a new project root, default is 'y'.

    	.Parameter BuildId
     	 The identifier of the current build.

    	.Parameter BuildRepoName
     	 The repository of the current build.

    	.Parameter BuildDefinitionName
     	 The definition name of the current build.

    	.Parameter BuildDefinitionNumber
     	 The definition number of the current build.

    	.Component
     	 Common

    	.Example
     	 Set-CmAzContext -ProjectRoot "C:/MyProject"

    	.Example
     	 Set-CmAzContext  `
      		-Environment "Development"
      		-ProjectRoot "C:/MyProject"
      		-ProjectConfirmation "y"
      		-BuildId "0.0.2"
      		-BuildRepoName "MyRepoName"
      		-BuildDefinitionName "Manual"
      		-BuildDefinitionNumber "1.0"
  	#>

	[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidGlobalVars", "", Justification = "Using a global variable for session state")]
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Low")]
	param(
		[string]$Environment = "Development",
		[Parameter(Mandatory = $true)]
		[string]$ProjectRoot,
		[string]$ProjectConfirmation = "n",
		[string]$BuildId = "001",
		[string]$BuildRepoName = "Local",
		[string]$BuildDefinitionName = "Manual",
		[string]$BuildDefinitionNumber = "0.0.1"
	)

  	$ErrorActionPreference = "Stop"

	try {

		if ($PSCmdlet.ShouldProcess("Environment:$Environment", "Set the session context")) {

			$dataFile = Import-PowerShellDataFile "$PSScriptRoot\..\..\Cloudmarque.Azure.psd1"

			$packageName = $dataFile.rootModule.TrimEnd(".psm1")
			$packageVersion = $dataFile.moduleVersion
			$date = get-date -UFormat "+%Y-%m-%dT%H:%M:%S.000Z"

			$isValid = Test-Path -LiteralPath $ProjectRoot -IsValid

			if (!$isValid) {
				throw "Project root $ProjectRoot is not valid"
			}

			$exists = Test-Path -LiteralPath $ProjectRoot

			if (!$exists -and $ProjectConfirmation -eq "n") {
				$ProjectConfirmation = Read-Host -Prompt "Create new project root? [y/n] (Default: n)"
			}

			# JB comment out project as developing level-x setting in cloudmarque-config
			# TODO workout how best to create level0,1,2 baseline settings: from cloudmarque-config or cloudmarque.azure\resources
			# if ($ProjectConfirmation -eq "y") {
			# 	New-CmAzProject -Project $ProjectRoot
			# }

			$namingFile = "$ProjectRoot/_names/tokens.yml"
			$namingConventions = Get-CmAzSettingsFile -Path $namingFile

			if (!$namingConventions.environments[$Environment.ToLower()]) {
				throw "Environment does not exist!"
			}

			if ($CMAZ_CTX) {
				Clear-CmAzContext
			}

			$global:CMAZ_CTX = @{
				Environment = $Environment;
				ProjectRoot = $ProjectRoot;
				PakageName = $packageName
				PackageVersion = $packageVersion;
				BuildId = $BuildId
				BuildRepoName = $BuildRepoName
				BuildDefinitionName = "$BuildDefinitionName ($BuildDefinitionNumber)"
				Date = $date
			}

			$global:CMAZ_CTX

			$env:CMAZ_CTX_ENV = ($global:CMAZ_CTX.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join "`n"

			if(!(Test-Path $PROFILE.CurrentUserCurrentHost)) {
				New-Item $PROFILE.CurrentUserCurrentHost -ItemType File -Force
			}

			$contextValue = ($global:CMAZ_CTX.GetEnumerator() | ForEach-Object { "$($_.Key) = `"$($_.Value)`"" }) -join ";"
			$profileValue = "`$global:CMAZ_CTX = New-Object PSObject -Property @{ $contextValue }"

			Add-Content -Path $Profile.CurrentUserCurrentHost -Value $profileValue

		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSitem);
	}
}