function Merge-HashTables() {

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

    $hashtableToAdd
}
