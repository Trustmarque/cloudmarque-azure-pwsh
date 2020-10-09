$includes = @(
    @{ Directory = "Private"; Export = $false },
    @{ Directory = "Public";  Export = $true  }
);

foreach ($includeProps in $includes) {

    $include = New-Object psobject -Property $includeProps;

    $items = Get-ChildItem -Path "$PSScriptRoot\$($include.Directory)\" -Filter "*.ps1" -Recurse -Force

    foreach($item in $items)  {
        
        . $item.FullName

        if ($include.Export) {
            Export-ModuleMember -Function $item.BaseName
        }
    }
}