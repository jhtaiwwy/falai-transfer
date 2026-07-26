Add-Type -AssemblyName System.Drawing

function Draw-Star($g, $cx, $cy, $size, $color) {
    $points = @()
    for ($i = 0; $i -lt 10; $i++) {
        $angle = [Math]::PI * ($i * 36 - 90) / 180
        $r = if ($i % 2 -eq 0) { $size } else { $size * 0.4 }
        $x = $cx + $r * [Math]::Cos($angle)
        $y = $cy + $r * [Math]::Sin($angle)
        $points += [System.Drawing.PointF]::new($x, $y)
    }
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillPolygon($brush, $points)
    $brush.Dispose()
}

function Create-Icon($size, $outputPath) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $scale = $size / 108.0
    
    # 背景圆角矩形
    $corner = 24 * $scale
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $corner * 2, $corner * 2, 180, 90)
    $path.AddLine($corner, 0, $size - $corner, 0)
    $path.AddArc($size - $corner * 2, 0, $corner * 2, $corner * 2, 270, 90)
    $path.AddLine($size, $corner, $size, $size - $corner)
    $path.AddArc($size - $corner * 2, $size - $corner * 2, $corner * 2, $corner * 2, 0, 90)
    $path.AddLine($size - $corner, $size, $corner, $size)
    $path.AddArc(0, $size - $corner * 2, $corner * 2, $corner * 2, 90, 90)
    $path.AddLine(0, $size - $corner, 0, $corner)
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(38, 39, 80))
    $g.FillPath($brush, $path)
    $brush.Dispose()
    $path.Dispose()
    
    # 星环
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(64, 255, 255, 255), 1.8 * $scale)
    $g.DrawEllipse($pen, [float](54 * $scale - 31 * $scale), [float](55 * $scale - 11 * $scale), [float](62 * $scale), [float](22 * $scale))
    $pen.Dispose()
    
    # 星环上的点
    $brush2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 233, 176))
    $g.FillEllipse($brush2, [float](85 * $scale - 2.4 * $scale), [float](55 * $scale - 2.4 * $scale), [float](4.8 * $scale), [float](4.8 * $scale))
    
    # 微星点
    $brush3 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(153, 255, 255, 255))
    $g.FillEllipse($brush3, [float](36 * $scale - 1.4 * $scale), [float](30 * $scale - 1.4 * $scale), [float](2.8 * $scale), [float](2.8 * $scale))
    $g.FillEllipse($brush3, [float](72 * $scale - 1.6 * $scale), [float](78 * $scale - 1.6 * $scale), [float](3.2 * $scale), [float](3.2 * $scale))
    $brush3.Dispose()
    
    # 主四角星（金色）
    $goldColor = [System.Drawing.Color]::FromArgb(255, 209, 102)
    Draw-Star $g (54 * $scale) (52 * $scale) (16 * $scale) $goldColor
    
    # 右上小星
    Draw-Star $g (76 * $scale) (32 * $scale) (6 * $scale) [System.Drawing.Color]::FromArgb(255, 233, 176)
    
    # 左下小星
    Draw-Star $g (30 * $scale) (72.5 * $scale) (5 * $scale) [System.Drawing.Color]::FromArgb(230, 210, 170)
    
    $brush2.Dispose()
    $bmp.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
}

Create-Icon 512 'E:\mobileApp\file-transfer\harmonyos\entry\src\main\resources\base\media\icon.png'
Create-Icon 216 'E:\mobileApp\file-transfer\harmonyos\entry\src\main\resources\base\media\icon_216.png'
Write-Host "Icons created successfully!"
