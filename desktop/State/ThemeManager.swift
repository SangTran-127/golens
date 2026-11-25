import Cocoa
import SwiftUI

struct Theme: Identifiable, Hashable {
    let id: String
    let name: String

    func isDark(systemDark: Bool) -> Bool {
        return resolvedIsDark
    }

    var resolvedIsDark: Bool {
        if id == "xcode" {
            return WorkspaceState.shared.systemAppearanceIsDark
        }
        return true
    }
    
    func backgroundColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1.0) : NSColor.white
        }
        switch id {
        case "dracula": return NSColor(red: 40/255, green: 42/255, blue: 54/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 40/255, green: 44/255, blue: 52/255, alpha: 1.0)
        case "monokai": return NSColor(red: 39/255, green: 40/255, blue: 34/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 26/255, green: 27/255, blue: 38/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 13/255, green: 17/255, blue: 23/255, alpha: 1.0)
        case "halloween": return NSColor(red: 25/255, green: 21/255, blue: 33/255, alpha: 1.0)
        case "noel": return NSColor(red: 20/255, green: 29/255, blue: 36/255, alpha: 1.0)
        case "tet": return NSColor(red: 31/255, green: 20/255, blue: 22/255, alpha: 1.0)
        default: return isDark ? NSColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1.0) : NSColor.white
        }
    }
    
    func textColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(white: 0.9, alpha: 1.0) : NSColor(white: 0.1, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 171/255, green: 178/255, blue: 191/255, alpha: 1.0)
        case "monokai": return NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 192/255, green: 202/255, blue: 245/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 205/255, green: 214/255, blue: 244/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 230/255, green: 237/255, blue: 243/255, alpha: 1.0)
        case "halloween": return NSColor(red: 245/255, green: 240/255, blue: 250/255, alpha: 1.0)
        case "noel": return NSColor(red: 242/255, green: 247/255, blue: 250/255, alpha: 1.0)
        case "tet": return NSColor(red: 250/255, green: 242/255, blue: 240/255, alpha: 1.0)
        default: return isDark ? NSColor(white: 0.9, alpha: 1.0) : NSColor(white: 0.1, alpha: 1.0)
        }
    }
    
    func insertionPointColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor.white : NSColor.black
        }
        switch id {
        case "dracula": return NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 82/255, green: 139/255, blue: 255/255, alpha: 1.0)
        case "monokai": return NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 192/255, green: 202/255, blue: 245/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 245/255, green: 224/255, blue: 220/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 88/255, green: 166/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 255/255, green: 159/255, blue: 67/255, alpha: 1.0)
        case "noel": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        default: return isDark ? NSColor.white : NSColor.black
        }
    }
    
    func keywordColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 252/255, green: 95/255, blue: 163/255, alpha: 1.0) : NSColor(red: 173/255, green: 61/255, blue: 163/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 255/255, green: 121/255, blue: 198/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 198/255, green: 120/255, blue: 221/255, alpha: 1.0)
        case "monokai": return NSColor(red: 249/255, green: 38/255, blue: 114/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 187/255, green: 154/255, blue: 247/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 203/255, green: 166/255, blue: 247/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 255/255, green: 123/255, blue: 114/255, alpha: 1.0)
        case "halloween": return NSColor(red: 201/255, green: 142/255, blue: 242/255, alpha: 1.0)
        case "noel": return NSColor(red: 255/255, green: 117/255, blue: 143/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 117/255, blue: 143/255, alpha: 1.0)
        default: return NSColor.systemPink
        }
    }
    
    func commentColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 108/255, green: 121/255, blue: 134/255, alpha: 1.0) : NSColor(red: 93/255, green: 108/255, blue: 121/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 98/255, green: 114/255, blue: 164/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 92/255, green: 99/255, blue: 112/255, alpha: 1.0)
        case "monokai": return NSColor(red: 117/255, green: 113/255, blue: 94/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 105/255, green: 114/255, blue: 156/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 127/255, green: 132/255, blue: 156/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 139/255, green: 148/255, blue: 158/255, alpha: 1.0)
        case "halloween": return NSColor(red: 138/255, green: 124/255, blue: 160/255, alpha: 1.0)
        case "noel": return NSColor(red: 122/255, green: 145/255, blue: 158/255, alpha: 1.0)
        case "tet": return NSColor(red: 158/255, green: 128/255, blue: 132/255, alpha: 1.0)
        default: return NSColor.systemGray
        }
    }
    
    func stringColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 252/255, green: 106/255, blue: 93/255, alpha: 1.0) : NSColor(red: 209/255, green: 47/255, blue: 27/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 241/255, green: 250/255, blue: 140/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 152/255, green: 195/255, blue: 121/255, alpha: 1.0)
        case "monokai": return NSColor(red: 230/255, green: 219/255, blue: 116/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 158/255, green: 206/255, blue: 106/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 166/255, green: 227/255, blue: 161/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 165/255, green: 214/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 255/255, green: 159/255, blue: 67/255, alpha: 1.0)
        case "noel": return NSColor(red: 82/255, green: 183/255, blue: 136/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 159/255, blue: 67/255, alpha: 1.0)
        default: return NSColor.systemRed
        }
    }
    
    func numberColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 208/255, green: 191/255, blue: 105/255, alpha: 1.0) : NSColor(red: 39/255, green: 42/255, blue: 216/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 189/255, green: 147/255, blue: 249/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 209/255, green: 154/255, blue: 102/255, alpha: 1.0)
        case "monokai": return NSColor(red: 174/255, green: 129/255, blue: 255/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 255/255, green: 158/255, blue: 100/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 250/255, green: 179/255, blue: 135/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 121/255, green: 192/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        case "noel": return NSColor(red: 255/255, green: 179/255, blue: 193/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        default: return NSColor.systemPurple
        }
    }
    
    func builtinColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 208/255, green: 168/255, blue: 92/255, alpha: 1.0) : NSColor(red: 173/255, green: 61/255, blue: 163/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 139/255, green: 233/255, blue: 253/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 86/255, green: 182/255, blue: 194/255, alpha: 1.0)
        case "monokai": return NSColor(red: 102/255, green: 217/255, blue: 239/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 125/255, green: 207/255, blue: 255/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 148/255, green: 226/255, blue: 213/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 121/255, green: 192/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        case "noel": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        case "tet": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        default: return NSColor.systemTeal
        }
    }
    
    func typeColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 178/255, green: 129/255, blue: 235/255, alpha: 1.0) : NSColor(red: 92/255, green: 38/255, blue: 153/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 139/255, green: 233/255, blue: 253/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 229/255, green: 192/255, blue: 123/255, alpha: 1.0)
        case "monokai": return NSColor(red: 102/255, green: 217/255, blue: 239/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 125/255, green: 207/255, blue: 255/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 249/255, green: 226/255, blue: 175/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 255/255, green: 166/255, blue: 87/255, alpha: 1.0)
        case "halloween": return NSColor(red: 216/255, green: 168/255, blue: 255/255, alpha: 1.0)
        case "noel": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        default: return NSColor.systemTeal
        }
    }
    
    func functionColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 93/255, green: 216/255, blue: 255/255, alpha: 1.0) : NSColor(red: 30/255, green: 61/255, blue: 89/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 80/255, green: 250/255, blue: 123/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 97/255, green: 175/255, blue: 239/255, alpha: 1.0)
        case "monokai": return NSColor(red: 166/255, green: 226/255, blue: 46/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 122/255, green: 162/255, blue: 247/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 137/255, green: 180/255, blue: 250/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 210/255, green: 168/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        case "noel": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        case "tet": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        default: return NSColor.systemGreen
        }
    }
    
    func propertyColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 131/255, green: 201/255, blue: 252/255, alpha: 1.0) : NSColor(red: 50/255, green: 109/255, blue: 116/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 255/255, green: 184/255, blue: 108/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 224/255, green: 108/255, blue: 117/255, alpha: 1.0)
        case "monokai": return NSColor(red: 253/255, green: 151/255, blue: 31/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 115/255, green: 218/255, blue: 202/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 180/255, green: 190/255, blue: 254/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 121/255, green: 192/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 88/255, green: 214/255, blue: 141/255, alpha: 1.0)
        case "noel": return NSColor(red: 142/255, green: 202/255, blue: 230/255, alpha: 1.0)
        case "tet": return NSColor(red: 88/255, green: 214/255, blue: 141/255, alpha: 1.0)
        default: return NSColor.systemOrange
        }
    }
    
    func namespaceColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 178/255, green: 129/255, blue: 235/255, alpha: 1.0) : NSColor(red: 135/255, green: 40/255, blue: 160/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 139/255, green: 233/255, blue: 253/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 97/255, green: 175/255, blue: 239/255, alpha: 1.0)
        case "monokai": return NSColor(red: 102/255, green: 217/255, blue: 239/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 122/255, green: 162/255, blue: 247/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 249/255, green: 226/255, blue: 175/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 255/255, green: 166/255, blue: 87/255, alpha: 1.0)
        case "halloween": return NSColor(red: 255/255, green: 159/255, blue: 67/255, alpha: 1.0)
        case "noel": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        default: return NSColor.systemTeal
        }
    }
    
    func parameterColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 158/255, green: 163/255, blue: 176/255, alpha: 1.0) : NSColor(red: 0/255, green: 0/255, blue: 0/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 255/255, green: 184/255, blue: 108/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 209/255, green: 154/255, blue: 102/255, alpha: 1.0)
        case "monokai": return NSColor(red: 253/255, green: 151/255, blue: 31/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 224/255, green: 175/255, blue: 104/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 242/255, green: 205/255, blue: 205/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 255/255, green: 166/255, blue: 87/255, alpha: 1.0)
        case "halloween": return NSColor(red: 255/255, green: 184/255, blue: 112/255, alpha: 1.0)
        case "noel": return NSColor(red: 142/255, green: 202/255, blue: 230/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 184/255, blue: 112/255, alpha: 1.0)
        default: return NSColor.systemOrange
        }
    }
    
    func variableColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return isDark ? NSColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1.0) : NSColor(red: 0/255, green: 0/255, blue: 0/255, alpha: 1.0)
        }
        switch id {
        case "dracula": return NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 224/255, green: 108/255, blue: 117/255, alpha: 1.0)
        case "monokai": return NSColor(red: 248/255, green: 248/255, blue: 242/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 192/255, green: 202/255, blue: 245/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 205/255, green: 214/255, blue: 244/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 230/255, green: 237/255, blue: 243/255, alpha: 1.0)
        case "halloween": return NSColor(red: 245/255, green: 240/255, blue: 250/255, alpha: 1.0)
        case "noel": return NSColor(red: 242/255, green: 247/255, blue: 250/255, alpha: 1.0)
        case "tet": return NSColor(red: 250/255, green: 242/255, blue: 240/255, alpha: 1.0)
        default: return NSColor.textColor
        }
    }
    
    func gutterBackgroundColor(isDark: Bool) -> NSColor {
        return backgroundColor(isDark: isDark)
    }
    
    func gutterBorderColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return NSColor.gridColor.withAlphaComponent(0.15)
        }
        return NSColor.white.withAlphaComponent(0.1)
    }
    
    func lineNumberColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return NSColor.secondaryLabelColor
        }
        switch id {
        case "dracula": return NSColor(red: 98/255, green: 114/255, blue: 164/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 92/255, green: 99/255, blue: 112/255, alpha: 1.0)
        case "monokai": return NSColor(red: 117/255, green: 113/255, blue: 94/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 105/255, green: 114/255, blue: 156/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 127/255, green: 132/255, blue: 156/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 139/255, green: 148/255, blue: 158/255, alpha: 1.0)
        case "halloween": return NSColor(red: 138/255, green: 124/255, blue: 160/255, alpha: 1.0)
        case "noel": return NSColor(red: 122/255, green: 145/255, blue: 158/255, alpha: 1.0)
        case "tet": return NSColor(red: 158/255, green: 128/255, blue: 132/255, alpha: 1.0)
        default: return NSColor.secondaryLabelColor
        }
    }

    
    func panelNSBackgroundColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return NSColor.windowBackgroundColor
        }
        switch id {
        case "dracula": return NSColor(red: 33/255, green: 34/255, blue: 44/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 33/255, green: 37/255, blue: 43/255, alpha: 1.0)
        case "monokai": return NSColor(red: 30/255, green: 31/255, blue: 28/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 22/255, green: 22/255, blue: 30/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 24/255, green: 24/255, blue: 37/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 22/255, green: 27/255, blue: 34/255, alpha: 1.0)
        case "halloween": return NSColor(red: 37/255, green: 30/255, blue: 48/255, alpha: 1.0)
        case "noel": return NSColor(red: 30/255, green: 43/255, blue: 52/255, alpha: 1.0)
        case "tet": return NSColor(red: 41/255, green: 26/255, blue: 29/255, alpha: 1.0)
        default: return NSColor.windowBackgroundColor
        }
    }

    func panelSecondaryTextNSColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return NSColor.secondaryLabelColor
        }
        switch id {
        case "dracula": return NSColor(red: 154/255, green: 165/255, blue: 206/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 148/255, green: 156/255, blue: 174/255, alpha: 1.0)
        case "monokai": return NSColor(red: 166/255, green: 162/255, blue: 140/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 138/255, green: 148/255, blue: 196/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 156/255, green: 162/255, blue: 190/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 145/255, green: 154/255, blue: 166/255, alpha: 1.0)
        case "halloween": return NSColor(red: 178/255, green: 168/255, blue: 194/255, alpha: 1.0)
        case "noel": return NSColor(red: 163/255, green: 184/255, blue: 194/255, alpha: 1.0)
        case "tet": return NSColor(red: 198/255, green: 174/255, blue: 178/255, alpha: 1.0)
        default: return NSColor.secondaryLabelColor
        }
    }

    func accentNSColor(isDark: Bool) -> NSColor {
        if id == "xcode" {
            return NSColor.controlAccentColor
        }
        switch id {
        case "dracula": return NSColor(red: 189/255, green: 147/255, blue: 249/255, alpha: 1.0)
        case "oneDark": return NSColor(red: 97/255, green: 175/255, blue: 239/255, alpha: 1.0)
        case "monokai": return NSColor(red: 253/255, green: 151/255, blue: 31/255, alpha: 1.0)
        case "tokyoNight": return NSColor(red: 122/255, green: 162/255, blue: 247/255, alpha: 1.0)
        case "catppuccin": return NSColor(red: 203/255, green: 166/255, blue: 247/255, alpha: 1.0)
        case "githubDark": return NSColor(red: 88/255, green: 166/255, blue: 255/255, alpha: 1.0)
        case "halloween": return NSColor(red: 179/255, green: 102/255, blue: 255/255, alpha: 1.0)
        case "noel": return NSColor(red: 76/255, green: 201/255, blue: 235/255, alpha: 1.0)
        case "tet": return NSColor(red: 255/255, green: 209/255, blue: 102/255, alpha: 1.0)
        default: return NSColor.controlAccentColor
        }
    }

    func accentColor(isDark: Bool) -> Color {
        if id == "xcode" {
            return Color.accentColor
        }
        return Color(nsColor: accentNSColor(isDark: isDark))
    }

    func terminalANSIColors(isDark: Bool) -> [(UInt8, UInt8, UInt8)] {
        if id == "xcode" && !isDark {
            return [
                (0x1A, 0x1A, 0x1A), (0xC4, 0x1A, 0x16), (0x00, 0x74, 0x00), (0x82, 0x6B, 0x28),
                (0x00, 0x00, 0xD6), (0xA9, 0x0D, 0x91), (0x1C, 0x6E, 0x7D), (0x5C, 0x63, 0x70),
                (0x6E, 0x6E, 0x73), (0xD1, 0x2F, 0x1B), (0x0B, 0x87, 0x0B), (0x9E, 0x74, 0x00),
                (0x27, 0x2A, 0xD8), (0xAD, 0x3D, 0xA3), (0x25, 0x82, 0x94), (0x1A, 0x1A, 0x1A)
            ]
        }
        switch id {
        case "dracula":
            return [
                (0x21, 0x22, 0x2C), (0xFF, 0x55, 0x55), (0x50, 0xFA, 0x7B), (0xF1, 0xFA, 0x8C),
                (0xBD, 0x93, 0xF9), (0xFF, 0x79, 0xC6), (0x8B, 0xE9, 0xFD), (0xF8, 0xF8, 0xF2),
                (0x62, 0x72, 0xA4), (0xFF, 0x6E, 0x6E), (0x69, 0xFF, 0x94), (0xFF, 0xFF, 0xA5),
                (0xD6, 0xAC, 0xFF), (0xFF, 0x92, 0xDF), (0xA4, 0xFF, 0xFF), (0xFF, 0xFF, 0xFF)
            ]
        case "oneDark":
            return [
                (0x28, 0x2C, 0x34), (0xE0, 0x6C, 0x75), (0x98, 0xC3, 0x79), (0xE5, 0xC0, 0x7B),
                (0x61, 0xAF, 0xEF), (0xC6, 0x78, 0xDD), (0x56, 0xB6, 0xC2), (0xAB, 0xB2, 0xBF),
                (0x5C, 0x63, 0x70), (0xE8, 0x83, 0x88), (0xA8, 0xCC, 0x8C), (0xEB, 0xCB, 0x8B),
                (0x71, 0xBA, 0xF2), (0xD2, 0x91, 0xE4), (0x66, 0xC4, 0xD0), (0xFF, 0xFF, 0xFF)
            ]
        case "monokai":
            return [
                (0x27, 0x28, 0x22), (0xF9, 0x26, 0x72), (0xA6, 0xE2, 0x2E), (0xF4, 0xBF, 0x75),
                (0x66, 0xD9, 0xEF), (0xAE, 0x81, 0xFF), (0xA1, 0xEF, 0xE4), (0xF8, 0xF8, 0xF2),
                (0x75, 0x71, 0x5E), (0xFD, 0x5F, 0xA0), (0xB6, 0xE6, 0x3E), (0xE6, 0xDB, 0x74),
                (0x82, 0xE3, 0xF4), (0xC4, 0xA3, 0xFF), (0xB7, 0xF5, 0xEC), (0xF9, 0xF8, 0xF5)
            ]
        case "tokyoNight":
            return [
                (0x15, 0x16, 0x1E), (0xF7, 0x76, 0x8E), (0x9E, 0xCE, 0x6A), (0xE0, 0xAF, 0x68),
                (0x7A, 0xA2, 0xF7), (0xBB, 0x9A, 0xF7), (0x7D, 0xCF, 0xFF), (0xA9, 0xB1, 0xD6),
                (0x56, 0x5F, 0x89), (0xFF, 0x89, 0x9D), (0xAF, 0xD6, 0x7A), (0xE9, 0xC5, 0x82),
                (0x8D, 0xB0, 0xF8), (0xC7, 0xAB, 0xF8), (0x97, 0xD8, 0xFF), (0xC0, 0xCA, 0xF5)
            ]
        case "catppuccin":
            return [
                (0x45, 0x47, 0x5A), (0xF3, 0x8B, 0xA8), (0xA6, 0xE3, 0xA1), (0xF9, 0xE2, 0xAF),
                (0x89, 0xB4, 0xFA), (0xF5, 0xC2, 0xE7), (0x94, 0xE2, 0xD5), (0xBA, 0xC2, 0xDE),
                (0x58, 0x5B, 0x70), (0xF3, 0x8B, 0xA8), (0xA6, 0xE3, 0xA1), (0xF9, 0xE2, 0xAF),
                (0x89, 0xB4, 0xFA), (0xCB, 0xA6, 0xF7), (0x89, 0xDC, 0xEB), (0xCD, 0xD6, 0xF4)
            ]
        case "githubDark":
            return [
                (0x48, 0x4F, 0x58), (0xFF, 0x7B, 0x72), (0x3F, 0xB9, 0x50), (0xD2, 0x99, 0x22),
                (0x58, 0xA6, 0xFF), (0xBC, 0x8C, 0xFF), (0x39, 0xC5, 0xCF), (0xB1, 0xBA, 0xC4),
                (0x6E, 0x76, 0x81), (0xFF, 0xA1, 0x98), (0x56, 0xD3, 0x64), (0xE3, 0xB3, 0x41),
                (0x79, 0xC0, 0xFF), (0xD2, 0xA8, 0xFF), (0x56, 0xD4, 0xDD), (0xF0, 0xF6, 0xFC)
            ]
        case "halloween":
            return [
                (0x28, 0x21, 0x36), (0xFF, 0x6B, 0x6B), (0x5C, 0xD6, 0x8D), (0xFF, 0x9F, 0x43),
                (0xA2, 0x9B, 0xFE), (0xD6, 0xA2, 0xE8), (0x48, 0xDB, 0xFB), (0xF5, 0xF0, 0xFA),
                (0x7E, 0x72, 0x96), (0xFF, 0x87, 0x87), (0x78, 0xE0, 0x8F), (0xFF, 0xBE, 0x76),
                (0xB8, 0xB2, 0xFF), (0xE2, 0xB8, 0xF0), (0x7E, 0xE7, 0xFC), (0xFF, 0xFF, 0xFF)
            ]
        case "noel":
            return [
                (0x1E, 0x2B, 0x36), (0xFF, 0x6B, 0x6B), (0x6E, 0xE7, 0xB7), (0xFC, 0xD3, 0x4D),
                (0x60, 0xA5, 0xFA), (0xF4, 0x72, 0xB6), (0x4C, 0xC9, 0xEB), (0xF2, 0xF7, 0xFA),
                (0x6A, 0x82, 0x94), (0xFF, 0x87, 0x87), (0x86, 0xEF, 0xAC), (0xFD, 0xE0, 0x47),
                (0x93, 0xC5, 0xFD), (0xF9, 0xA8, 0xD4), (0x7D, 0xD3, 0xFC), (0xFF, 0xFF, 0xFF)
            ]
        case "tet":
            return [
                (0x2E, 0x1D, 0x20), (0xFF, 0x6B, 0x6B), (0x7E, 0xE0, 0x81), (0xFF, 0xD1, 0x66),
                (0x70, 0xC1, 0xFF), (0xFF, 0x8F, 0xA3), (0x64, 0xDF, 0xDF), (0xFA, 0xF2, 0xF0),
                (0x91, 0x73, 0x78), (0xFF, 0x87, 0x87), (0x98, 0xEB, 0x9B), (0xFF, 0xDF, 0x8E),
                (0x94, 0xD2, 0xFF), (0xFF, 0xB3, 0xC1), (0x8E, 0xEC, 0xEC), (0xFF, 0xFF, 0xFF)
            ]
        default:
            return [
                (0x2E, 0x34, 0x36), (0xFC, 0x6A, 0x5D), (0x67, 0xB7, 0xA4), (0xD0, 0xBF, 0x69),
                (0x5D, 0xD8, 0xFF), (0xFC, 0x5F, 0xA3), (0x83, 0xC9, 0xFC), (0xE6, 0xE6, 0xE6),
                (0x6C, 0x79, 0x86), (0xFF, 0x85, 0x7A), (0x7F, 0xCE, 0xBC), (0xE5, 0xD4, 0x7E),
                (0x7A, 0xE1, 0xFF), (0xFF, 0x7E, 0xB6), (0x9C, 0xD6, 0xFF), (0xFF, 0xFF, 0xFF)
            ]
        }
    }
}

extension Theme {
    private static func blended(_ base: NSColor, toward target: NSColor, fraction: CGFloat) -> NSColor {
        let baseSRGB = base.usingColorSpace(.sRGB) ?? base
        let targetSRGB = target.usingColorSpace(.sRGB) ?? target
        return baseSRGB.blended(withFraction: fraction, of: targetSRGB) ?? base
    }

    func codeBackgroundNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        backgroundColor(isDark: isDark)
    }

    func codeTextPrimaryNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        let base = textColor(isDark: isDark)
        guard highContrast else { return base }
        return Self.blended(base, toward: isDark ? .white : .black, fraction: 0.35)
    }

    func codeTextSecondaryNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        let base = panelSecondaryTextNSColor(isDark: isDark)
        guard highContrast else { return base }
        return Self.blended(base, toward: textColor(isDark: isDark), fraction: 0.40)
    }

    func codeLineNumberNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        let base = lineNumberColor(isDark: isDark)
        guard highContrast else { return base }
        return Self.blended(base, toward: textColor(isDark: isDark), fraction: 0.40)
    }

    func codeCurrentLineFillNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        let alpha: CGFloat = highContrast ? (isDark ? 0.08 : 0.06) : (isDark ? 0.045 : 0.03)
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
    }

    func codeIndentGuideNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(highContrast ? 0.20 : 0.10)
    }

    func codeLensMarginBackgroundNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        let alpha: CGFloat = highContrast ? 0.05 : 0.025
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
    }

    func codeLensDividerNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(highContrast ? 0.22 : 0.10)
    }

    func codeLensActionTextNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        let base = panelSecondaryTextNSColor(isDark: isDark)
        let target = textColor(isDark: isDark)
        return Self.blended(base, toward: target, fraction: highContrast ? 0.55 : 0.30)
    }

    func codeLensMetadataTextNSColor(isDark: Bool, highContrast: Bool) -> NSColor {
        codeTextSecondaryNSColor(isDark: isDark, highContrast: highContrast)
    }
}

enum DataVizPalette {
    private static func stepColor(fraction: Double, isDark: Bool) -> Color {
        if fraction < 0.25 {
            if isDark {
                return Color(red: 230.0 / 255.0, green: 184.0 / 255.0, blue: 92.0 / 255.0)
            }
            return Color(red: 217.0 / 255.0, green: 164.0 / 255.0, blue: 65.0 / 255.0)
        } else if fraction < 0.50 {
            if isDark {
                return Color(red: 235.0 / 255.0, green: 158.0 / 255.0, blue: 62.0 / 255.0)
            }
            return Color(red: 212.0 / 255.0, green: 136.0 / 255.0, blue: 42.0 / 255.0)
        } else if fraction < 0.75 {
            if isDark {
                return Color(red: 224.0 / 255.0, green: 126.0 / 255.0, blue: 65.0 / 255.0)
            }
            return Color(red: 196.0 / 255.0, green: 104.0 / 255.0, blue: 45.0 / 255.0)
        } else {
            if isDark {
                return Color(red: 212.0 / 255.0, green: 101.0 / 255.0, blue: 66.0 / 255.0)
            }
            return Color(red: 176.0 / 255.0, green: 78.0 / 255.0, blue: 46.0 / 255.0)
        }
    }

    static func heatFill(fraction: Double, isDark: Bool) -> Color {
        let clamped = min(max(fraction, 0), 1)
        let alpha: Double
        if clamped < 0.25 {
            alpha = isDark ? 0.20 : 0.16
        } else if clamped < 0.50 {
            alpha = isDark ? 0.26 : 0.22
        } else if clamped < 0.75 {
            alpha = isDark ? 0.32 : 0.28
        } else {
            alpha = isDark ? 0.38 : 0.34
        }
        return stepColor(fraction: clamped, isDark: isDark).opacity(alpha)
    }

    static func heatStroke(fraction: Double, isDark: Bool) -> Color {
        let clamped = min(max(fraction, 0), 1)
        let alpha: Double = clamped < 0.50 ? 0.68 : 0.85
        return stepColor(fraction: clamped, isDark: isDark).opacity(alpha)
    }

    static func traceStateColor(_ kind: String, isDark: Bool) -> Color {
        switch kind {
        case "running":
            return isDark
                ? Color(red: 72.0 / 255.0, green: 184.0 / 255.0, blue: 200.0 / 255.0)
                : Color(red: 26.0 / 255.0, green: 127.0 / 255.0, blue: 142.0 / 255.0)
        case "runnable":
            return isDark
                ? Color(red: 102.0 / 255.0, green: 160.0 / 255.0, blue: 232.0 / 255.0)
                : Color(red: 53.0 / 255.0, green: 110.0 / 255.0, blue: 178.0 / 255.0)
        case "syscall":
            return isDark
                ? Color(red: 218.0 / 255.0, green: 166.0 / 255.0, blue: 76.0 / 255.0)
                : Color(red: 168.0 / 255.0, green: 116.0 / 255.0, blue: 36.0 / 255.0)
        case "blocked":
            return isDark
                ? Color(red: 148.0 / 255.0, green: 158.0 / 255.0, blue: 172.0 / 255.0)
                : Color(red: 112.0 / 255.0, green: 120.0 / 255.0, blue: 132.0 / 255.0)
        case "gc":
            return isDark
                ? Color(red: 184.0 / 255.0, green: 134.0 / 255.0, blue: 222.0 / 255.0)
                : Color(red: 132.0 / 255.0, green: 82.0 / 255.0, blue: 168.0 / 255.0)
        default:
            return .secondary
        }
    }
}

class ThemeManager {
    static let shared = ThemeManager()
    static let mascotCostumeKey = "GoLensGopherCostume"

    let themes: [Theme] = [
        Theme(id: "xcode", name: "Xcode (System)"),
        Theme(id: "tokyoNight", name: "Tokyo Night"),
        Theme(id: "catppuccin", name: "Catppuccin Mocha"),
        Theme(id: "githubDark", name: "GitHub Dark"),
        Theme(id: "dracula", name: "Dracula"),
        Theme(id: "oneDark", name: "One Dark"),
        Theme(id: "monokai", name: "Monokai"),
        Theme(id: "halloween", name: "Halloween"),
        Theme(id: "noel", name: "Noel"),
        Theme(id: "tet", name: "Lunar New Year")
    ]

    func theme(withId id: String) -> Theme {
        return themes.first(where: { $0.id == id }) ?? themes[0]
    }

    func resolvedSeasonalPack(themeId: String, costume: String? = nil) -> String? {
        let mode = costume ?? UserDefaults.standard.string(forKey: Self.mascotCostumeKey) ?? "default"
        switch mode {
        case "halloween", "noel", "tet":
            return mode
        default:
            return nil
        }
    }

    func effectiveCostumeId(themeId: String, costume: String? = nil) -> String {
        let mode = costume ?? UserDefaults.standard.string(forKey: Self.mascotCostumeKey) ?? "default"
        switch mode {
        case "halloween", "noel", "tet", "hacker":
            return mode
        default:
            return "default"
        }
    }

    func appIconImage(themeId: String, costume: String? = nil) -> NSImage {
        let effective = effectiveCostumeId(themeId: themeId, costume: costume)
        if effective != "default",
           let url = AppResourceBundle.url(forResource: "golens-icon-\(effective)", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let url = AppResourceBundle.url(forResource: "GoLens", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApp.applicationIconImage
    }

    func applyAppIcon(themeId: String, costume: String? = nil) {
        DispatchQueue.main.async {
            let isDefault = self.effectiveCostumeId(themeId: themeId, costume: costume) == "default"
            NSApplication.shared.applicationIconImage = isDefault ? nil : self.appIconImage(themeId: themeId, costume: costume)
        }
    }
}

enum GopherLore {
    static let costumeOrder = ["default", "halloween", "noel", "tet", "hacker"]

    static func nextCostume(after current: String) -> String {
        guard let idx = costumeOrder.firstIndex(of: current) else { return "default" }
        return costumeOrder[(idx + 1) % costumeOrder.count]
    }

    static func costumeLabel(_ costume: String, themeId: String) -> String {
        let effective = ThemeManager.shared.effectiveCostumeId(themeId: themeId, costume: costume)
        switch effective {
        case "halloween": return "Halloween"
        case "noel": return "Noel"
        case "tet": return "Lunar New Year"
        case "hacker": return "Hacker"
        default: return "Classic Go"
        }
    }

    static func welcomeGreeting(themeId: String, costume: String) -> String {
        "Native Go IDE for macOS"
    }

    static func emptyEditorSubtitle(themeId: String, costume: String) -> String {
        let openQuickly = KeymapStore.shared.display("file.openQuickly")
        return openQuickly.isEmpty
            ? "Select a file in the navigator or use File ▸ Open Quickly."
            : "Select a file in the navigator or press \(openQuickly) to Open Quickly."
    }

    static func emptyIssuesSubtitle(themeId: String, costume: String) -> String {
        "No errors or warnings reported by gopls."
    }

    static func emptyGitSubtitle(themeId: String, costume: String) -> String {
        "All changes have been committed."
    }
}
