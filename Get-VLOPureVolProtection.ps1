<#
.SYNOPSIS
Checks to ensure volumes have snapshots and data in those snapshots
.DESCRIPTION
All volume created on the arrays should have local snapshots.  The script will check to ensure any volumes that do not are reported.
.PARAMETER mail
Email address for recipients
.PARAMETER Arrays
Which arrays the script should run on
.EXAMPLE
.\Get-VLOPureVolProtection.ps1 -mail <user>@<domain>
.NOTES
    Name:               Check all volumes on all arrays for snapshots
    Created:            02/21/2024
    Author:             Thomas Spivey
#>

param (
  [Parameter(Mandatory=$true)]
  [string[]] $Arrays = @('')
)

#Function that uses a PS Object to keep volumes that have no data in their snapshots or do not have snapshots
function addObject {
    param (
        [string]$array,
        [string]$volName,
        [string]$note
    )

    $addObject = [ordered]@{
      'ARRAY'        = $array
      'VOLUME NAME'  = $volName
      'NOTE'         = $note
    }
    
    $Info += New-Object PSCustomObject -Property $addObject
    $Info
}

foreach ($array in $Arrays) {
    #Connect to array and save array object information via custom module
    $pfa = Connect-VLOPure -array $array | Out-Null

    #Get a list of volume snapshots
    $snaps = Invoke-Pfa2RestCommand -Array $pfa -Method GET -RelativeUri /api/2.26/volume-snapshots

    #Convert json to PS object
    $jsonSnaps = $snaps | ConvertFrom-Json

    #Select certain properties from output and sort
    $sortedSnaps = $jsonSnaps.items | Select-Object -Property source,name,@{label="Local Time";expression={(([System.DateTimeOffset]::FromUnixTimeSeconds($_.created/1000)).DateTime.ToLocalTime()).ToString("s")}},suffix,serial,@{label="Snapshot space (MB)";expression={[math]::ceiling($_.space.snapshots/1024/1024)}} | Sort-Object -Property created

    #Determine which volumes have snapshots of zero bytes
    $zeroSnaps = $sortedSnaps | Where-Object -Property 'Snapshot space (MB)' -EQ 0 | Sort-Object -Property {$_.source.name} -Unique | Select-Object -Property @{label="name";expression={$_.source.name}}

    #Even though some snapshots have zero size not all may.  We want to know if all snapshots have zero size so we sum them all.  IF all have zer size we report.
    $zeroSnaps.name | ForEach-Object {
        $noSnapSpace = ($sortedSnaps | Where-Object -Property suffix -Like $_ | Select-Object -Property "Snapshot space (MB)" | Measure-Object -Property "Snapshot space (MB)" -Sum).sum
        if ( $noSnapSpace -EQ 0 ) {
            #Add to custom PS object
            addObject -array $array -volName $_ -note "0 bytes for all snapshots"
        }
    }

    #Get a list of just the volume names for all snapshots.  This will be used to compare the query of volume names later.
    $snapVolNames = $jsonSnaps.items.source.name | Sort-Object -Unique
    
    #Only keep volume names that are local and not replicated volumes.  New array is used so that it is not fixed size and can be added to.
    $localSnapVolNames = [Collections.ArrayList]@()

    #If a volume name is not pre-pended with a source array, keep.
    ForEach ( $vol in $snapVolNames ) {
        if ( $vol -notmatch "^\w+:{1}.+$" ) {
            [void]$localSnapVolNames.Add($vol)
        }
    }

    #Get a list of volume names to compare with volumes that have snapshots.
    $vols = Invoke-Pfa2RestCommand -Method GET -RelativeUri /api/2.26/volumes
    $jsonVols = $vols | ConvertFrom-Json
    $volNames = $jsonVols.items.name | Sort-Object

    #Compare the volume names in the snapshots with volume names from array.  Keep any differences. This will be a list of volumes that do not have snapshot protection.
    $diff = Compare-Object -ReferenceObject $localSnapVolNames -DifferenceObject $volNames -PassThru
    $diff | ForEach-Object {
        #Add to custom PS object
        addObject -array $array -volName $_ -note "no spapshots found on array for volume"
    }

    Disconnect-Pfa2Array -Array $pfa
}
