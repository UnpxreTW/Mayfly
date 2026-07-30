//
//  MayflyUITests
//
//  Copyright © 2026 Unpxre
//  Licensed under the Apache License 2.0. See LICENSE for details.
//
//  SPDX-License-Identifier: Apache-2.0

import Foundation
import NymphKit

@testable import MayflyUI

/// model 測試共用的素材與組裝（清單面與細節欄面各自一個 suite、素材只留一份）。
enum SessionFixtures {

	static let sessionA: SessionSummary = .init(
		id: "mfly-aaaaaaaa",
		state: .ready,
		ip: "192.168.64.10",
		golden: "sonoma",
		cpus: 4,
		memoryGiB: 8,
		uptimeSeconds: 65
	)

	/// 與 ``sessionA`` 同 id、資料已推進的那份（釘住細節欄取的是新清單、不是舊快照）。
	static let sessionAAdvanced: SessionSummary = .init(
		id: "mfly-aaaaaaaa",
		state: .ready,
		ip: "192.168.64.10",
		golden: "sonoma",
		cpus: 4,
		memoryGiB: 8,
		uptimeSeconds: 900
	)

	static let sessionB: SessionSummary = .init(
		id: "mfly-bbbbbbbb",
		state: .booting,
		ip: nil,
		golden: "sonoma",
		cpus: 2,
		memoryGiB: 4,
		uptimeSeconds: 3
	)

	static func endpoint(socketPresent: Bool) -> DaemonEndpoint {
		DaemonEndpoint(socketPath: "/tmp/mayfly-library-test/nymph.sock", isSocketPresent: socketPresent)
	}

	@MainActor
	static func model(
		querier: any SessionQuerying,
		endpoint: DaemonEndpoint = SessionFixtures.endpoint(socketPresent: false)
	) -> SessionLibraryModel {
		SessionLibraryModel(querier: querier, resolveEndpoint: { endpoint })
	}

	static func failure(in phase: SessionLibraryModel.LibraryPhase) -> DaemonFailure? {
		guard case let .unavailable(failure) = phase else {
			return nil
		}
		return failure
	}
}
