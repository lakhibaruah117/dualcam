import CoreImage
import CoreGraphics

enum Cropper {
    /// Center-crops an image to the aspect of `size` and scales it to exactly `size`.
    static func crop(_ img: CIImage, to size: CGSize) -> CIImage {
        let e = img.extent
        let ta = size.width / size.height
        var w = e.width, h = e.height
        if w / h > ta { w = h * ta } else { h = w / ta }
        let r = CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h)
        let s = size.width / w
        return img.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
    static let vertical = CGSize(width: 1080, height: 1920)
    static let horizontal = CGSize(width: 1920, height: 1080)
}
