import Foundation

/// Plain 3D vector. Accelerations are expressed in g, rotation rates in rad/s.
public struct Vector3: Equatable, Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public static let zero = Vector3(x: 0, y: 0, z: 0)

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    public func dot(_ other: Vector3) -> Double { x * other.x + y * other.y + z * other.z }

    public static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }
}

/// Unit quaternion (w + xi + yj + zk) used for gimbal-lock free attitude algebra.
public struct Quaternion: Equatable, Hashable, Sendable, Codable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    /// Rotation of `angleRadians` around `axis` (normalised internally).
    public init(axis: Vector3, angleRadians: Double) {
        let length = axis.magnitude
        guard length > 0 else {
            self = .identity
            return
        }
        let half = angleRadians / 2
        let s = sin(half) / length
        self.init(w: cos(half), x: axis.x * s, y: axis.y * s, z: axis.z * s)
    }

    /// Builds the quaternion whose `eulerAngles` return the given angles (degrees).
    /// Composition order is yaw (Z), then roll (Y), then pitch (X).
    public init(pitchDegrees: Double, rollDegrees: Double, yawDegrees: Double) {
        let pitch = Quaternion(axis: Vector3(x: 1, y: 0, z: 0), angleRadians: pitchDegrees * .pi / 180)
        let roll = Quaternion(axis: Vector3(x: 0, y: 1, z: 0), angleRadians: rollDegrees * .pi / 180)
        let yaw = Quaternion(axis: Vector3(x: 0, y: 0, z: 1), angleRadians: yawDegrees * .pi / 180)
        self = yaw * roll * pitch
    }

    public var norm: Double { (w * w + x * x + y * y + z * z).squareRoot() }

    public var normalized: Quaternion {
        let n = norm
        guard n > 0 else { return .identity }
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public var conjugate: Quaternion { Quaternion(w: w, x: -x, y: -y, z: -z) }

    public var inverse: Quaternion {
        let n2 = w * w + x * x + y * y + z * z
        guard n2 > 0 else { return .identity }
        let c = conjugate
        return Quaternion(w: c.w / n2, x: c.x / n2, y: c.y / n2, z: c.z / n2)
    }

    /// Hamilton product.
    public static func * (lhs: Quaternion, rhs: Quaternion) -> Quaternion {
        Quaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        )
    }

    /// Attitude of `self` expressed relative to `reference`, mirroring
    /// `CMAttitude.multiply(byInverseOf:)`: `reference⁻¹ ⊗ self`.
    public func multiply(byInverseOf reference: Quaternion) -> Quaternion {
        (reference.inverse * self).normalized
    }

    /// Euler angles in degrees. Pitch rotates around X (nodding), roll around Y
    /// (lateral tilt), yaw around Z (turning).
    public var eulerAngles: EulerAngles {
        let q = normalized
        let pitch = atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
        let sinRoll = max(-1, min(1, 2 * (q.w * q.y - q.z * q.x)))
        let roll = asin(sinRoll)
        let yaw = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        return EulerAngles(
            pitchDegrees: pitch * 180 / .pi,
            rollDegrees: roll * 180 / .pi,
            yawDegrees: yaw * 180 / .pi
        )
    }
}

/// Head attitude in degrees: pitch θ, roll ϕ, yaw ψ.
public struct EulerAngles: Equatable, Sendable, Codable {
    public var pitchDegrees: Double
    public var rollDegrees: Double
    public var yawDegrees: Double

    public static let zero = EulerAngles(pitchDegrees: 0, rollDegrees: 0, yawDegrees: 0)

    public init(pitchDegrees: Double, rollDegrees: Double, yawDegrees: Double) {
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.yawDegrees = yawDegrees
    }
}
