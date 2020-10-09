<#
    
    .Synopsis
	 This Azure Automation runbook removes resources with $deleteTag tag set to today.

	.Description
	 Completes the following:
	    * Connects to Azure AD with a Service Principal and Connect-AzAccount.
		* Removes all the resources with $deleteTag tag matching today's date.
        * Removes resource groups with $deleteTag tag matching today's date.

#>

# Write-Output is used instead of Write-Verbose for logging on Automation account console.

$ErrorActionPreference = "Stop"

# Get the Service Principal connection details for the Connection name
$servicePrincipalConnection = Get-AutomationConnection -Name "AzureRunAsConnection"

# Logging in to Azure AD with Service Principal
Write-Output "Logging in to Azure AD..."
Connect-AzAccount -TenantId $servicePrincipalConnection.TenantId `
    -ApplicationId $servicePrincipalConnection.ApplicationId `
    -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint

$deleteTag = "cm-delete"

Write-Output "Checking for resource groups to be deleted.."
$resourceGroupstoDelete = Get-CmAzService -ServiceKey $deleteTag -Service $(Get-date -Format "dd/MM/yyyy") -IsResourceGroup

if ($resourceGroupstoDelete) {
    Write-Output "Below resource groups will be deleted.."
    $resourceGroupstoDelete | Write-Output

    $resourceGroupstoDelete | ForEach-Object {
        Write-Output "Removing resource group $($_.ResourceGroupName)"
        Remove-AzResourceGroup -Id $_.ResourceId -Force > $null
    }
}
else {
    Write-Output "No resource group tagged for deletion"
}

Write-Output "Checking for resources to be deleted.."
$resourcestoDelete = Get-CmAzService -ServiceKey $deleteTag -Service $(Get-date -Format "dd/MM/yyyy")

if ($resourcestoDelete) {
    Write-Output "Below resources will be deleted.."
    $resourcestoDelete | Write-Output

    $resourcestoDelete | ForEach-Object {
        Write-Output "Removing resource : $($_.Name)"
        Remove-AzResource -ResourceId $_.resourceId -Force > $null
    }
}
else {
    Write-Output "No specific resources tagged for deletion"
}