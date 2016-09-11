//
//  AsyncFetcher.swift
//  Haneke
//
//  Created by Hermes Pique on 1/2/16.
//  Copyright © 2016 Haneke. All rights reserved.
//

import Foundation
@testable import Haneke

class AsyncFetcher<T : DataConvertible> : Fetcher<T> {

    let getValue : () -> T.Result

    init(key: String, @autoclosure(escaping) value getValue : () -> T.Result) {
        self.getValue = getValue
        super.init(key: key)
    }

    override func fetch(failure fail: ((Error?) -> ()), success succeed: (T.Result) -> ()) {
        let value = getValue()
        DispatchQueue.global(attributes: DispatchQueue.GlobalAttributes.qosDefault).async {
            DispatchQueue.main.async {
                succeed(value)
            }
        }
    }

    override func cancelFetch() {}

}
