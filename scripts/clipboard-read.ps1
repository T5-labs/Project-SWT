Add-Type -Assembly System.Windows.Forms
$img = [System.Windows.Forms.Clipboard]::GetImage()
if ($img) {
    $path = [System.IO.Path]::Combine($env:TEMP, "swt-clipboard.png")
    $img.Save($path)
    Write-Output $path
} else {
    Write-Output "no-image"
}
