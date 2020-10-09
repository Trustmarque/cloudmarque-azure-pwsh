
function New-CmAzCore {

    <#
        .Synopsis

        .Description

        .Parameter

        .Component
         Common

        .Example
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
    param(
        [string]$Name = '',
        [string]$Location
    )

    if($PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Deploy Core resources")) {

        $architecture = "Core";
        $environment = "Production"

        $nameRgCore = Get-CmAzResourceName -Generator "Groups" -Resource "ResourceGroup" -Location $location -Architecture $architecture -Environment $environment -Name $name
        $nameRgCoreKeys = Get-CmAzResourceName -Generator "Groups" -Resource "ResourceGroup" -Location $location -Architecture $architecture -Environment $environment -Name $name
        $nameRgCoreLogs = Get-CmAzResourceName -Generator "Groups" -Resource "ResourceGroup" -Location $location -Architecture $architecture -Environment $environment -Name $name

        $nameLogWorkspace = Get-CmAzResourceName -Generator "Default" -Resource "LogAnalyticsworkspace" -Location $location -Architecture $architecture -Environment $environment -Name $name

        New-AzResourceGroup -Name $nameRgCore -Location $Location
        New-AzResourceGroup -Name $nameRgCoreKeys -Location $Location
        New-AzResourceGroup -Name $nameRgCoreLogs -Location $Location

        New-AzResourceGroupDeployment `
            -ResourceGroupName $nameRgCoreLogs `
            -TemplateFile "$PSScriptRoot/_templates/logging/azuredeploy.json" `
            -TemplateParameterFile "$PSScriptRoot/_templates/logging/azuredeploy.parameters.json" `
            -WorkspaceName $nameLogWorkspace `
            -Location $Location
    }
}