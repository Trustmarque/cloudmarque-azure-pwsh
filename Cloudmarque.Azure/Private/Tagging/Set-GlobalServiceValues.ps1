function Set-GlobalServiceValues() {

    param(
        [parameter(Mandatory = $true)]
        [Hashtable]$GlobalServiceContainer,
        [parameter(Mandatory = $true)]
        [String]$ServiceKey,
        [parameter(Mandatory = $true)]
        [HashTable]$ResourceServiceContainer,
        [Switch]$IsDependency,
        [Switch]$AllowMissing
    )

    if ($IsDependency) {
        $serviceGroup = "dependencies"
        $errorMessage = "Please provide a valid global/local dependency value for $ServiceKey."
    }
    else {
        $serviceGroup = "publish"
        $errorMessage = "Please provide a valid global/local $ServiceKey value to publish."
    }

    Write-Verbose "Setting global service $serviceGroup on all applicable resources..."

    $missingGlobalService = (!$GlobalServiceContainer -Or !$GlobalServiceContainer.service -Or !$GlobalServiceContainer.service[$serviceGroup])
    $missingResourceService = (!$ResourceServiceContainer -Or !$ResourceServiceContainer.service -Or !$ResourceServiceContainer.service[$serviceGroup])

    if ($missingGlobalService -and $missingResourceService) {

        if($AllowMissing) {
            return
        }
        else {
            Write-Error $errorMessage -Category InvalidArgument
        }
    }
    else {

        if (!$ResourceServiceContainer.service) {
            $ResourceServiceContainer.service = @{}
        }

        if (!$ResourceServiceContainer.service[$serviceGroup]) {
            $ResourceServiceContainer.service[$serviceGroup] = @{}
        }

        if (!$ResourceServiceContainer.service[$serviceGroup][$ServiceKey]) {
            # If the service value isn't set on the resource, set it the global service value.
            $ResourceServiceContainer.service[$serviceGroup][$ServiceKey] = $GlobalServiceContainer.service[$serviceGroup][$ServiceKey]
        }
    }
}