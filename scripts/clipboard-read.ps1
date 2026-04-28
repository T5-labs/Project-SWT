Add-Type -Assembly System.Windows.Forms
$img = [System.Windows.Forms.Clipboard]::GetImage()
if ($img) {
    $path = [System.IO.Path]::Combine($env:TEMP, "swt-clipboard.png")
    try {
        $img.Save($path)
        Write-Output $path
    } catch {
        $msg = $_.Exception.Message -replace "`r`n|`r|`n", " "
        Write-Output "save-error:$msg"
        exit 1
    }
} else {
    Write-Output "no-image"
}
