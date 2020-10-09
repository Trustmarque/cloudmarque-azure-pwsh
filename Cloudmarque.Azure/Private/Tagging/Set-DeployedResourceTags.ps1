function Set-DeployedResourceTags() {

    param(
        [AllowEmptyString()]
        [String]$TagSettingsFile,
        [Parameter(ParameterSetName = "Resources")]
        [AllowEmptyCollection()]
        [Array]$ResourceIds,
        [Parameter(ParameterSetName = "ResourceGroups")]
        [AllowEmptyCollection()]
        [Array]$ResourceGroupIds
    )

    if(!$ResourceIds -and !$ResourceGroupIds) {
        Write-Warning "No resources provided for tagging."
        return
    }

    if ($TagSettingsFile) {
        $SettingsObject = Get-CmAzSettingsFile -Path $TagSettingsFile
    }
    else {
        $SettingsObject = Get-CmAzSettingsFile -Path "$((Get-CmAzContext).projectRoot)/_tags/globalTags.yml"
    }

    if ($ResourceIds) {
        $SettingsObject.resourceIds = $ResourceIds
    }
    elseif($ResourceGroupIds) {
        $SettingsObject.resourceGroupIds = $ResourceGroupIds
    }

    Write-Verbose "Setting tagging details for deployed resources..."
    Set-CmAzCoreTag -SettingsObject $SettingsObject > $null
}