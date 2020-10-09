function ConvertTo-HashTable() {

    param(
        [parameter(Mandatory = $true)]
        [PSCustomObject]$objectToConvert
    )

    $hashTable = @{}

    foreach ($property in $objectToConvert.psObject.properties) {
        $hashTable[$property.Name] = $property.Value
    }

    $hashTable
}