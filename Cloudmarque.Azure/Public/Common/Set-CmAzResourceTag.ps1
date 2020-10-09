function Set-CmAzResourceTag {

  <#
		.Synopsis
		 Set tags on resource group and resources

		.Description
		 Sets (updates (merges)) mandatory and custom tags on resource group, either specific resources or all the resources in a resource group.

		.Parameter ResourceGroupName
		 Name of the Resource Group for tag updates (merges)  

		.Parameter TagResourcesOnly
		 Flag used to determin if only resources in the Resource Group should be udpated (default false)  

		.Parameter SettingsFile
		 File path for the settings file to be converted into a settings object.

		.Parameter SettingsObject
		 Object containing the configuration values required to run this cmdlet.

		.Component
		 Common

		.Example
		 Set-CmAzCoreTag -SettingsFile "c:/directory/settingsFile.yml"

		.Example
		 Set-CmAzCoreTag -SettingsObject $settings
	#>

  [CmdletBinding(SupportsShouldProcess, ConfirmImpact = "Medium")]
  param (
    #[parameter(Mandatory = $true, ParameterSetName = "Resource Group Name")]
    [String]$ResourceGroupName,
    [bool]$TagResourcesOnly = $false,
    #[parameter(Mandatory = $true, ParameterSetName = "Settings File")]
    [String]$SettingsFile,
    #[parameter(Mandatory = $true, ParameterSetName = "Settings Object")]
    [Object]$SettingsObject
  )

  $ErrorActionPreference = "Stop"

  function MergeHashTables() {

    param(
      [parameter(Mandatory = $true)]
      [hashtable]$hashtableToFilter,
      [parameter(Mandatory = $true)]
      [hashtable]$hashtableToAdd
    )

    $hashtableToFilter.GetEnumerator() | ForEach-Object {
      if ($_.key -and $hashtableToAdd.keys -notcontains $_.key) {
        $hashtableToAdd.Add($_.key, $_.value)
      }
    }

    return $hashtableToAdd
  }

  try {

    if (!$PSCmdlet.ShouldProcess((Get-CmAzSubscriptionName), "Set tags for resources")) { return }
		
    $ctx = Get-CmAzContext -ThrowIfUnavailable
    $globaltags = Get-CmAzSettingsFile -Path "$($ctx.ProjectRoot)\_names\tags.yml";

    if ($SettingsFile -and !$SettingsObject) {
      $SettingsObject = Get-CmAzSettingsFile -Path $SettingsFile
    }
    elseif (!$SettingsFile -and !$SettingsObject) {
      Write-Error "No valid input settings." -Category InvalidArgument -CategoryTargetName "SettingsObject"
    }

    Write-Verbose "Checking that the expected mandatory tags exist and are not empty..."
    $expectedMandatoryTagKeys = $globaltags.Tags.Mandatory.Keys
    if ($SettingsObject.Tags.Mandatory) {
      Write-Verbose "Merging global and template tags..."
      $mergedMandatoryTags = MergeHashTables -hashtableToFilter $globaltags.Tags.Mandatory -hashtableToAdd $SettingsObject.Tags.Mandatory
    }
    else {
      $mergedMandatoryTags = $globaltags.Tags.Mandatory
    }
	
    $mandatoryTagsVariableName = "Tags.Mandatory"
    $missingMandatoryKeys = $expectedMandatoryTagKeys | Where-Object { $mergedMandatoryTags.Keys -NotContains $_ }

    if ($missingMandatoryKeys) {

      $missingMandatoryKeysValue = [string]$missingMandatoryKeys

      Write-Error "$missingMandatoryKeysValue is missing from the mandatory tags section." -Category InvalidArgument -CategoryTargetName $mandatoryTagsVariableName
    }

    [System.Collections.ArrayList]$missingMandatoryTagsValues = @()
    foreach ($mergedMandatoryTagKey in $mergedMandatoryTags.Keys) {
      if (!$mergedMandatoryTags[$mergedMandatoryTagKey]) {
        $missingMandatoryTagsValues.Add($mergedMandatoryTagKey)
      }
    }

    if ($missingMandatoryTagsValues.Count -gt 0) {
      $missingMandatoryTagValue = [string]$missingMandatoryTagsValues

      Write-Error "Mandatory tag(s) ($missingMandatoryTagValue) missing from the merged global and local mandatory tags." -Category InvalidArgument -CategoryTargetName $missingMandatoryTagValue
    }

    $allTags = $SettingsObject.Tags.Mandatory
    if ($SettingsObject.Tags.Custom) {

      Write-Verbose "Setting custom tags..."

      foreach ($customTagKey in $SettingsObject.Tags.Custom.Keys) {
        $Value = $SettingsObject.Tags.Custom[$customTagKey]
        Write-verbose "Tag - $customTagKey will be set as $Value..."
      }

      $allTags += $SettingsObject.Tags.Custom
    }
    else {
      Write-Verbose "No custom tags."
    }
    
    $tagResourcesOnlySetting = $false
    if ($SettingsObject.Tags.tagResourcesOnly) { $tagResourcesOnlySetting = [bool]$SettingsObject.Tags.tagResourcesOnly }

    if (!$TagResourcesOnly -and !$tagResourcesOnlySetting) {
      Write-Verbose "Setting tags for Resource Group $($ResourceGroupName)..."
      Set-AzResourceGroup -Name $ResourceGroupName -Tag $allTags | Out-Null
    }
    else {
      Write-Verbose "Not setting tags for Resource Group $($ResourceGroupName). tagResourcesOnlySetting ($tagResourcesOnlySetting), TagResourcesOnly Parameter $($TagResourcesOnly)."
    }

    foreach ($resourceType in $SettingsObject.Tags.resourceTypes) {

      [String]$resourceTypeKey = [String]$resourceType.Keys[0]
            
      switch ($resourceTypeKey) {

        "resourceTypeLike" {  

          $resourceTypeSearchString = "*{0}*" -f [String]$resourceType.Values[0]
          Write-Verbose "Fetching Resource Group $($ResourceGroupName) Resource Ids where ResourceTypeLike ($resourceTypeSearchString) .."
            
          $resourceIds = Get-AzResource -ResourceGroupName $ResourceGroupName | Where-Object ResourceType -like  "$resourceTypeSearchString" | Select-Object -ExpandProperty ResourceId
    
          try {
            foreach ($resourceId in $ResourceIds) {
              Write-Verbose "Update (merge) tags for ($resourceId)..."
              Update-AzTag -ResourceId "$resourceId" -Tag $allTags -Operation Merge | Out-Null
            }
          }
          catch {
            Write-Error "Issue locating resource: $resourceId." -Category ObjectNotFound -CategoryTargetName $resourceId
          }
    
        }
        "resourceTypeEquals" {  

          $resourceTypeSearchString = "{0}" -f [String]$resourceType.Values[0]
          Write-Verbose "Fetching Resource Group $($ResourceGroupName) Resource Ids where ResourceTypeEquals ($resourceTypeSearchString) .."

          $resourceIds = Get-AzResource -ResourceGroupName $ResourceGroupName | Where-Object ResourceType -EQ "$resourceTypeSearchString" | Select-Object -ExpandProperty ResourceId

          try {
            foreach ($resourceId in $ResourceIds) {
              Write-Verbose "Update (merge) tags for ($resourceId)..."
              Update-AzTag -ResourceId "$resourceId" -Tag $allTags -Operation Merge | Out-Null
            }

          }
          catch {
            Write-Error "Issue locating resource: $resourceId." -Category ObjectNotFound -CategoryTargetName $resourceId
          }

        }
        Default {
          Write-Error "Unsupported resourceType tag key ($resourceTypeKey) - allowed resourceTypes tag are 'resourceTypeLike', 'resourceTypeEquals'."
        }
      }
    }

    foreach ($resourceId in $SettingsObject.Tags.ResourceIds) {
      try {
        Write-Verbose "Update (merge) tags for ($resourceId)..."
        Update-AzTag -ResourceId "$resourceId" -Tag $allTags -Operation Merge | Out-Null
      }
      catch {
        Write-Error "Issue locating resource: $resourceId." -Category ObjectNotFound -CategoryTargetName $resourceId
      }
    }


    Write-Verbose "Finished!"

  }
  catch {
    $PSCmdlet.ThrowTerminatingError($PSItem);
  }
}