import CoreGraphics
import Foundation

func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL:", what); exit(1) } }

let editor = CGRect(x: 0, y: 100, width: 900, height: 500)
func line(at y: CGFloat) -> CGRect { CGRect(x: 200, y: y, width: 60, height: 16) }

let top = PopupPlacement.resolve(anchor: line(at: 120), bounds: editor, naturalHeight: 300)
expect(top.edge == .below, "a line near the top opens below")
expect(top.edgeY == 120 + 16 + 8, "below placement starts one gap under the line")
expect(top.availableHeight == 600 - 8 - (136 + 8), "below placement may use the editor down to its margin")

let bottom = PopupPlacement.resolve(anchor: line(at: 560), bounds: editor, naturalHeight: 300)
expect(bottom.edge == .above, "a line just above the bottom panel flips above")
expect(bottom.edgeY == 560 - 8, "above placement ends one gap over the line")
expect(bottom.availableHeight == (560 - 8) - (100 + 8), "above placement may use the editor up to its margin")
expect(bottom.edgeY - bottom.availableHeight >= editor.minY, "flipped popover stays inside the editor")

let shortNearBottom = PopupPlacement.resolve(anchor: line(at: 500), bounds: editor, naturalHeight: 60)
expect(shortNearBottom.edge == .below, "a short popover that fits below stays below")

let tallLower = PopupPlacement.resolve(anchor: line(at: 400), bounds: editor, naturalHeight: 900)
expect(tallLower.edge == .above, "a popover that fits nowhere takes the larger side")
let tallUpper = PopupPlacement.resolve(anchor: line(at: 200), bounds: editor, naturalHeight: 900)
expect(tallUpper.edge == .below, "the larger side wins when it is below")

let cramped = PopupPlacement.resolve(anchor: line(at: 110), bounds: CGRect(x: 0, y: 100, width: 900, height: 40), naturalHeight: 300)
expect(cramped.availableHeight == PopupPlacement.minimumHeight, "a tiny editor still leaves a readable popover")

print("ok")
