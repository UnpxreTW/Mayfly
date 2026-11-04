//
//  LinuxNodeKit
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import ContainerizationOCI
import CryptoKit
import Foundation

/// 把一份 rootfs tar 封成單層 OCI image layout 目錄，交給 `ImageStore.load(from:)` 載入。
///
/// 用途是「從 base 映像起容器、跑完設定、把結果固化成新映像」的最後一步：容器內整個 rootfs
/// 匯成一份 tar，這裡把它包成一顆只有這一層的映像。不經 registry——寫出來的目錄就是
/// OCI image layout，載入、備份、搬機都用同一種形狀。
///
/// - 層用**未壓縮**的 `application/vnd.oci.image.layer.v1.tar`：未壓縮時 diffID 就是層本身的
///   digest，只要算一次雜湊；代價是映像在磁碟上多佔壓縮省下的那一份空間。
/// - config 從 base 映像複製執行參數（`Env`／`Cmd`／`WorkingDir`／`Labels` 等）與平台欄，
///   `rootfs.diff_ids` 只剩這一層、`history` 只剩一條。base 的分層與歷史不保留——單層固化
///   本來就把它們攤平了，留著反而與實際層數對不上。
/// - 不寫 index blob：`index.json` 直接指向 manifest，由載入端依 config 的平台欄補一份
///   index（上游 `ImportOperation` 的既有行為）。
public enum SingleLayerImageLayout {

	// MARK: Public

	/// 寫 layout 時的失敗面。
	public enum LayoutError: Error, Equatable {

		/// 層檔不存在。
		case layerMissing(path: String)

		/// 目的目錄已存在且非空——layout 要寫進一個乾淨的目錄，不與別的東西混堆。
		case directoryNotEmpty(path: String)

		/// 別名或標籤組不出合法的 OCI 參照。
		case invalidReference(String)
	}

	/// 寫完的映像：用這個參照從 image store 取回它。
	public struct Output: Sendable, Equatable {

		/// 載入後在 image store 裡的參照。
		public let reference: String

		/// manifest 的 digest（`sha256:<hex>`）。
		public let manifestDigest: String

		/// 唯一那一層的 digest（未壓縮，同時也是 diffID）。
		public let layerDigest: String

		/// 層的位元組數。
		public let layerSize: Int64
	}

	/// 本機固化的映像一律掛在這個 registry 網域下。
	///
	/// 刻意選一個解析不到的網域：image store 以參照字串精確比對、命中就不往外拉，所以正常情況
	/// 下不會有網路請求；萬一本機的映像被刪了，往外拉也只會在網域解析那一步失敗，不會從公開
	/// registry 拉到一顆同名的別人的映像。
	public static let localDomain: String = "mayfly.local"

	/// 層的 media type（未壓縮 tar）。
	public static let layerMediaType: String = MediaTypes.imageLayer

	/// 組出本機映像的參照：`mayfly.local/<小寫別名>:<標籤>`。
	///
	/// - Parameters:
	///   - alias: 別名表裡的別名；OCI 的 repository 名只收小寫，故轉小寫。
	///   - tag: 標籤，同一個別名每固化一次換一個，舊的那顆仍可用舊參照取回。
	/// - Returns: 通過 OCI 參照語法檢查的參照。
	/// - Throws: ``LayoutError/invalidReference(_:)``——別名不合別名表的字元規則，或組出來的
	///   字串不是合法的 OCI 參照（例如別名以 `-` 結尾、標籤含 `/`）。
	public static func reference(alias: String, tag: String) throws -> String {
		guard LinuxImageManifest.isValidAlias(alias) else { throw LayoutError.invalidReference(alias) }
		let candidate: String = "\(localDomain)/\(alias.lowercased()):\(tag)"
		let parsed: Reference
		do {
			parsed = try Reference.parse(candidate)
		} catch {
			throw LayoutError.invalidReference(candidate)
		}
		guard
			parsed.domain == localDomain,
			parsed.tag == tag
		else { throw LayoutError.invalidReference(candidate) }
		return candidate
	}

	/// 把層檔封成 layout 寫進 `directory`。
	///
	/// - Parameters:
	///   - layer: rootfs 的未壓縮 tar；**會被搬進 layout**（不複製，GB 級的檔不值得多寫一份），
	///     呼叫端應放在與 `directory` 同一個卷上。搬移排在最後兩步（寫 `oci-layout`、`index.json`）之前，
	///     那兩步失敗時層檔留在 `<directory>/blobs/sha256/` 下、不在原路徑。
	///   - baseConfig: base 映像的 config。
	///   - reference: 載入後的參照（見 ``reference(alias:tag:)``）。
	///   - createdBy: 寫進 `history` 那一條的 `created_by`，記下這顆映像是怎麼來的。
	///   - baseReference: base 映像的參照，寫進 manifest 的 `org.opencontainers.image.base.name`。
	///   - baseDigest: base 映像的 digest；有值時寫進 `org.opencontainers.image.base.digest`。
	///   - created: 建立時刻。
	///   - directory: layout 目錄；不存在就建，存在則必須是空的。
	/// - Returns: 寫出的映像的參照與 digest。
	/// - Throws: ``LayoutError``，或讀寫檔案時的 `Foundation` 錯誤。
	public static func write(
		layer: URL,
		baseConfig: ContainerizationOCI.Image,
		reference: String,
		createdBy: String,
		baseReference: String,
		baseDigest: String?,
		created: Date,
		into directory: URL
	) throws -> Output {
		let fileManager: FileManager = .default
		guard fileManager.fileExists(atPath: layer.path) else { throw LayoutError.layerMissing(path: layer.path) }
		try prepareEmptyDirectory(directory)
		let blobs: URL = directory.appending(component: "blobs").appending(component: "sha256")
		try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)

		let layerHex: String = try LinuxKernelCache.sha256(of: layer)
		let layerSize: Int64 = try fileSize(of: layer)
		let layerDescriptor: Descriptor = .init(mediaType: layerMediaType, digest: "sha256:\(layerHex)", size: layerSize)

		let timestamp: String = ISO8601DateFormatter().string(from: created)
		let config: ContainerizationOCI.Image = .init(
			created: timestamp,
			author: baseConfig.author,
			architecture: baseConfig.architecture,
			os: baseConfig.os,
			osVersion: baseConfig.osVersion,
			osFeatures: baseConfig.osFeatures,
			variant: baseConfig.variant,
			config: baseConfig.config,
			rootfs: .init(type: "layers", diffIDs: [layerDescriptor.digest]),
			history: [.init(created: timestamp, createdBy: createdBy, comment: "base: \(baseReference)")]
		)
		let configDescriptor: Descriptor = try writeBlob(config, mediaType: MediaTypes.imageConfig, into: blobs)

		var annotations: [String: String] = ["org.opencontainers.image.base.name": baseReference]
		if let baseDigest {
			annotations["org.opencontainers.image.base.digest"] = baseDigest
		}
		let manifest: Manifest = .init(config: configDescriptor, layers: [layerDescriptor], annotations: annotations)
		var manifestDescriptor: Descriptor = try writeBlob(manifest, mediaType: MediaTypes.imageManifest, into: blobs)
		manifestDescriptor.platform = Platform(
			arch: baseConfig.architecture,
			os: baseConfig.os,
			osFeatures: baseConfig.osFeatures,
			variant: baseConfig.variant
		)
		// 三個鍵都寫：上游讀名字時依序認這三個（`LocalOCILayoutClient.getImageReferencefromDescriptor`），
		// 其他工具讀 layout 時各認各的，寫齊了誰讀都拿得到同一個名字。
		manifestDescriptor.annotations = [
			AnnotationKeys.containerizationImageName: reference,
			AnnotationKeys.containerdImageName: reference,
			AnnotationKeys.openContainersImageName: reference
		]

		// 層檔最後才搬：前面任何一步失敗時，GB 級的 tar 還留在呼叫端給的原路徑，換個目錄就能重試。
		try fileManager.moveItem(at: layer, to: blobs.appending(component: layerHex))
		try encoder.encode(["imageLayoutVersion": "1.0.0"]).write(to: directory.appending(component: "oci-layout"))
		try encoder.encode(Index(manifests: [manifestDescriptor])).write(to: directory.appending(component: "index.json"))
		return Output(
			reference: reference,
			manifestDigest: manifestDescriptor.digest,
			layerDigest: layerDescriptor.digest,
			layerSize: layerSize
		)
	}

	// MARK: Private

	/// JSON 一律排序鍵、不跳脫斜線：同樣的內容每次寫出同樣的位元組，digest 才穩定。
	private static var encoder: JSONEncoder {
		let encoder: JSONEncoder = .init()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return encoder
	}

	/// 確保 `directory` 存在且為空。
	/// - Parameter directory: 目的目錄。
	/// - Throws: ``LayoutError/directoryNotEmpty(path:)``，或建目錄失敗時的 `Foundation` 錯誤。
	private static func prepareEmptyDirectory(_ directory: URL) throws {
		let fileManager: FileManager = .default
		if fileManager.fileExists(atPath: directory.path) {
			let contents: [String] = try fileManager.contentsOfDirectory(atPath: directory.path)
			guard contents.isEmpty else { throw LayoutError.directoryNotEmpty(path: directory.path) }
			return
		}
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	/// 把一份 JSON 文件寫成 blob。
	/// - Parameters:
	///   - value: 要寫的文件。
	///   - mediaType: 描述子上的 media type。
	///   - blobs: `blobs/sha256` 目錄。
	/// - Returns: 指向這份 blob 的描述子。
	/// - Throws: 編碼或寫檔失敗時的錯誤。
	private static func writeBlob(_ value: some Encodable, mediaType: String, into blobs: URL) throws -> Descriptor {
		let data: Data = try encoder.encode(value)
		let hex: String = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
		try data.write(to: blobs.appending(component: hex))
		return Descriptor(mediaType: mediaType, digest: "sha256:\(hex)", size: Int64(data.count))
	}

	/// 檔案位元組數。
	/// - Parameter url: 檔案路徑。
	/// - Returns: 位元組數。
	/// - Throws: 讀不到屬性時的 `Foundation` 錯誤。
	private static func fileSize(of url: URL) throws -> Int64 {
		let attributes: [FileAttributeKey: Any] = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attributes[.size] as? NSNumber)?.int64Value ?? 0
	}
}
