import UIKit

/// Colours of the web app (web/app.css :root), so the native panel and the page look like one surface.
enum Theme {
    static let ground = UIColor(red: 10 / 255, green: 19 / 255, blue: 22 / 255, alpha: 1)      // --ground   #0a1316
    static let surface = UIColor(red: 17 / 255, green: 32 / 255, blue: 38 / 255, alpha: 1)     // --surface  #112026
    static let line = UIColor(red: 31 / 255, green: 53 / 255, blue: 64 / 255, alpha: 1)        // --line     #1f3540
    static let ink = UIColor(red: 231 / 255, green: 239 / 255, blue: 241 / 255, alpha: 1)      // --ink      #e7eff1
    static let muted = UIColor(red: 132 / 255, green: 160 / 255, blue: 168 / 255, alpha: 1)    // --muted    #84a0a8
    static let sand = UIColor(red: 233 / 255, green: 184 / 255, blue: 96 / 255, alpha: 1)      // --sand     #e9b860
    static let sandInk = UIColor(red: 27 / 255, green: 19 / 255, blue: 5 / 255, alpha: 1)      // --sand-ink #1b1305
    static let loss = UIColor(red: 1, green: 111 / 255, blue: 111 / 255, alpha: 1)             // --loss     #ff6f6f
}
