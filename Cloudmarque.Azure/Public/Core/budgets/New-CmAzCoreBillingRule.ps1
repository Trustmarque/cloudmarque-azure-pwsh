function New-CmAzCoreBillingRule {

	<#
		.Synopsis
	 	 Deploys a set of budgets at the subscription level.

		.Description
		 Completes the following:
			* Deploys a set of budgets at the subscription level.
			* Applies filtering via tags (cm-charge: accountnumber) to budgets for resource targeting.
			* Sets the action group to be notified once the threshold for a budget is met.

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Core

		.Example
		 New-CmAzCoreBillingRule -SettingsFile "c:/directory/settingsFile.yml"

		.Example
		 New-CmAzCoreBillingRule -SettingsObject $settings
	#>

	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
	param(
		[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
		[String]$SettingsFile,
		[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
		[Object]$SettingsObject
	)

	$ErrorActionPreference = "Stop"

	try {

		if ($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploying billing rules")) {

			if ($SettingsFile -and !$SettingsObject) {
				$SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
			}
			elseif (!$SettingsFile -and !$SettingsObject) {
				Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
			}

			if (!$SettingsObject.location) {
				Write-Error "Please provide a valid location." -Category InvalidArgument -CategoryTargetName "Location"
			}

			if (!$SettingsObject.budgets) {
				Write-Error "Please provide at least one budget." -Category InvalidArgument -CategoryTargetName "Budgets"
			}

			foreach($budget in $SettingsObject.budgets) {

				Write-Verbose "Validating budget: $($budget.name)..."

				if (!$budget.name) {
					Write-Error "Please provide a valid budget name." -Category InvalidArgument -CategoryTargetName "Budgets.Name"
				}
				elseif (!$budget.category) {
					Write-Error "Please provide a valid category." -Category InvalidArgument -CategoryTargetName "Budgets.Category"
				}
				elseif (!$budget.accountNumber) {
					Write-Error "Please provide a valid budget account number" -Category InvalidArgument -CategoryTargetName "Budgets.AccountNumber"
				}
				elseif (!$budget.timegrain) {
					Write-Error "Please provide a valid timegrain." -Category InvalidArgument -CategoryTargetName "Budgets.Timegrain"
				}
				elseif (!$budget.amount) {
					Write-Error "Please ensure the budget amount is greater than 0." -Category InvalidArgument -CategoryTargetName "Budgets.Amount"
				}
				elseif (!$budget.thresholds) {
					Write-Error "Please provide budget thresholds that are greater than 0." -Category InvalidArgument -CategoryTargetName "Budgets.Thresholds"
				}
				elseif (!($budget.startDate -Is [DateTime])) {
					Write-Error "Please ensure the budget start date is a valid date." -Category InvalidArgument -CategoryTargetName "Budgets.StartDate"
				}
				elseif (!($budget.endDate -Is [DateTime])) {
					Write-Error "Please ensure the budget end date is a valid date." -Category InvalidArgument -CategoryTargetName "Budgets.EndDate"
				}

				Write-Verbose "Generating budget name..."
				$budget.name = Get-CmAzResourceName -Resource "Budget" -Architecture "Core" -Region $SettingsObject.location -Name $budget.name

				Set-GlobalServiceValues -GlobalServiceContainer $SettingsObject -ServiceKey "actiongroup" -ResourceServiceContainer $budget -IsDependency

				$actionGroupResourceId = (Get-CmAzService -Service $budget.service.dependencies.actiongroup -ThrowIfUnavailable -ThrowIfMultiple).resourceId

				# Workaround as ARM templates don't support additional copy objects nested within a copied resource.
				# Required for multiple notifications over multiple budgets.

				Write-Verbose "Creating notifications for budget..."
				$notifications = @{ }

				for ($i = 0; $i -lt $budget.thresholds.count; $i++) {

					$notifications["Notification$i"] = @{
						enabled = $true;
						operator = "GreaterThanOrEqualTo";
						threshold = $budget.thresholds[$i];
						contactGroups = @($actionGroupResourceId);
						contactRoles = @(
							"Owner",
							"Contributor",
							"Reader"
						)
					}
				}

				$budget.notifications = $notifications
			}

			Write-Verbose "Deploying budgets..."
			New-AzDeployment `
				-Location $SettingsObject.location `
				-TemplateFile "$PSScriptRoot\New-CmAzCoreBillingRule.json" `
				-AccountFlagName "cm-charge" `
				-Budgets $SettingsObject.budgets

			Write-Verbose "Finished!"
		}
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($PSItem);
	}
}