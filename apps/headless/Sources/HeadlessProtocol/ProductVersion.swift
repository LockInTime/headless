import CHeadlessVersion

/// The product release version embedded at compile time. This is independent
/// from the wire protocol version used for compatibility checks.
public let headlessProductVersion = String(cString: headless_product_version())
