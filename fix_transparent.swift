import Foundation
import WebKit
import Cocoa

let svgPath = "/Users/zulfuyildiz/Desktop/ZyPlayer/icon.svg"
let outPath = "/Users/zulfuyildiz/Desktop/ZyPlayer/icon_clean.png"

guard let svgData = try? Data(contentsOf: URL(fileURLWithPath: svgPath)),
      let svgString = String(data: svgData, encoding: .utf8) else {
    exit(1)
}

let html = """
<!DOCTYPE html>
<html>
<head>
<style>
  * { margin: 0; padding: 0; }
  body, html { margin: 0; padding: 0; width: 1024px; height: 1024px; overflow: hidden; background: rgba(0,0,0,0); }
  svg { width: 1024px; height: 1024px; display: block; }
</style>
</head>
<body style="background: transparent;">
\(svgString)
</body>
</html>
"""

let app = NSApplication.shared
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
webView.setValue(false, forKey: "drawsBackground") // WebKit transparent background

webView.loadHTMLString(html, baseURL: nil)

DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    let config = WKSnapshotConfiguration()
    config.rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    webView.takeSnapshot(with: config) { image, error in
        guard let image = image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            exit(1)
        }
        
        // Remove any white background pixels in the 4 corners outside squircle
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        
        for y in 0..<height {
            for x in 0..<width {
                var color = bitmap.colorAt(x: x, y: y)
                if let c = color {
                    let r = c.redComponent
                    let g = c.greenComponent
                    let b = c.blueComponent
                    // If pure white or background bleed in corners
                    if r > 0.98 && g > 0.98 && b > 0.98 {
                        bitmap.setColorAt(NSColor(red: 0, green: 0, blue: 0, alpha: 0), x: x, y: y)
                    }
                }
            }
        }

        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("Successfully rendered clean transparent PNG without white corners!")
        }
        exit(0)
    }
}

app.run()
