<#
.SYNOPSIS
    PowerShell module to split one or many input files into smaller files with specified line count.
.DESCRIPTION
    
.EXAMPLE
    PS C:\> Split-File foo.txt -Split 100 -Header 2 -AddHeaders
.INPUTS
    Inputs (if any)
.OUTPUTS
    Output (if any)
.NOTES
    General notes
#>

function Get-Encoding {
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]
        $Path
    )

    process {
        $bom = New-Object -TypeName System.Byte[](4)
        $file = New-Object System.IO.FileStream($Path, 'Open', 'Read')

        $null = $file.Read($bom,0,4)
        $file.Close()
        $file.Dispose()

        $enc = "Default"
        if ($bom[0] -eq 0x2b -and $bom[1] -eq 0x2f -and $bom[2] -eq 0x76)
            { $enc = "UTF7" }
        if ($bom[0] -eq 0xff -and $bom[1] -eq 0xfe)
            { $enc = "Unicode" }
        if ($bom[0] -eq 0xfe -and $bom[1] -eq 0xff)
            { $enc = "BigEndianUnicode" }
        if ($bom[0] -eq 0x00 -and $bom[1] -eq 0x00 -and $bom[2] -eq 0xfe -and $bom[3] -eq 0xff)
            { $enc = "UTF32" }
        if ($bom[0] -eq 0xef -and $bom[1] -eq 0xbb -and $bom[2] -eq 0xbf)
            { $enc = "UTF8" }
        
        $enc
    }
}

function Split-File {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,
                    Position=0,
                    ValueFromPipeline=$true,
                    ValueFromPipelineByPropertyName = $true,
                    HelpMessage="Path to one or more files.")]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string[]] $Path,

        [Parameter(Mandatory=$false,
                    Position=1,
                    HelpMessage="Export path of converted file")]
        [string[]] $ExportPath,
        
        [Parameter(Mandatory=$true,
                    HelpMessage="Number of lines to split input file on")]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Split,
        
        [Parameter(Mandatory=$false,
                    HelpMessage="Number of header rows in input file (defaults to 1)")]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $Header = 1,
        
        [Parameter(Mandatory=$false,
                    HelpMessage="Skip header from original file in resulting files (defaults to false")]
        [switch] $SkipHeader,

        [Parameter(Mandatory=$false,
                    HelpMessage="Encoding to use on both input and output files,tries to guess encoding if not specified")]
        [ValidateSet('Default','ASCII','UTF7','UTF8', 'Unicode','UTF32', 'BigEndianUnicode')]
        [string] $Encoding,

        [Parameter(Mandatory=$false,
                    HelpMessage="Include batch/chunk in the filename instead of current number in the sequence (defaults to falsee)")]
        [switch] $BatchNaming
    )

    begin {
        if (Test-Path -PathType Leaf -Path $Path) {
            $files = Get-ChildItem -File $Path
        } else {
            Write-Error "Invalid path"
            break
        }

        # Set up the export path
        if (!$ExportPath -or !(Test-Path $ExportPath -PathType Container)) {
            $ExportPath = Split-Path $Path -Resolve
        }
    }
    
    process {
        $Processed = 0
        foreach ($file in $files) {
            $FilePath = ((Resolve-Path $file.FullName).ToString() -replace "(^.*::)")
            $ProgressActivity = "Splitting $($file.Name):"
            Write-Host "Splitting $($file.Name)"
            Write-Progress -Activity $ProgressActivity `
                -Status "Calculating total number of output files" `
                -PercentComplete 0
                
            if (-not $Encoding) {
                $Encoding = Get-Encoding -Path ((Resolve-Path $Path).ToString() -replace "(^.*::)")
            }
            $EncodingObject = switch ($Encoding) {
                "UTF7"              { [System.Text.Encoding]::UTF7 ; break }
                "Unicode"           { [System.Text.Encoding]::Unicode ; break }
                "BigEndianUnicode"  { [System.Text.Encoding]::BigEndianUnicode ; break }
                "UTF32"             { [System.Text.Encoding]::UTF32 ; break }
                "UTF8"              { [System.Text.Encoding]::UTF8 ; break }
                default             { [System.Text.Encoding]::Default ; break }
            }
            
            try {
                $FileReader = New-Object System.IO.StreamReader $FilePath, $EncodingObject
            } catch {
                Write-Error "Error: Could not open $($FilePath)"
                break
            }

            $TotalLines     = -$Header + $((Get-Content $file -ReadCount 1000 -Encoding "Default" | ForEach-Object {$x += $_.Count });$x)
            $TotalBatches   = [Math]::Ceiling($TotalLines / $Split)
            $FileHeader     = [System.Collections.ArrayList]@()
            
            $Counter = 0
            while ($Counter -lt $Header) {
                if (($Counter % ($Header / 20)) -eq 0 -or $Counter -eq 0) {
                    Write-Progress -Activity $ProgressActivity `
                        -Status "Reading header" `
                        -PercentComplete ([Math]::Ceiling($Counter / $Header * 100))
                }
                
                $null = $FileHeader.Add($FileReader.ReadLine())
                $Counter++
            }
            
            $Batch = 1
            $Counter = 1
            while ($FileReader.EndOfStream -ne $true) {
                $CurrentBatch = if ($Batch -eq $TotalBatches) { $TotalLines } else { $Counter + $Split - 1 }
                $Suffix = if ($BatchNaming) { $Counter.ToString() + "-" + ($CurrentBatch).ToString() }
                          else { $Batch.ToString().PadLeft($TotalBatches.ToString().Length, '0') }

                $ExportFile = (Join-Path -Path $ExportPath `
                    -ChildPath ($file.BaseName + "_" `
                    + $Suffix `
                    + $file.Extension)).ToString() -replace "(^.*::)"

                Write-Host "-> $ExportFile"
                Write-Progress -Activity $ProgressActivity `
                    -Status "Writing $ExportFile (of $TotalBatches)" `
                    -PercentComplete ([Math]::Ceiling($Batch / $TotalBatches * 100))
                
                try {
                    $FileWriter = New-Object System.IO.StreamWriter $ExportFile, $false, $EncodingObject
                } catch {
                    $_.Exception.Message
                    Write-Error "Error: Could not write file: $ExportFile"
                    break
                }
                
                if (!$SkipHeader) {
                    foreach ($line in $FileHeader) {
                        $FileWriter.WriteLine($line)
                    }
                }
                
                while ($Counter -le $CurrentBatch -and $FileReader.EndOfStream -ne $true) {
                    $FileWriter.WriteLine($FileReader.ReadLine())
                    $Counter++
                }

                $FileWriter.Close()
                $Batch++
            }
            
            $FileReader.Close()
            $Processed++
        }
    }
    
    end {
        $FileReader.Close() | Out-Null
        $FileWriter.Close() | Out-Null

        Write-Host "`n$Processed file(s) processed`n"
    }
}

Export-ModuleMember -Function Split-File