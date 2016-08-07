//
//  DiskCache.swift
//  Haneke
//
//  Created by Hermes Pique on 8/10/14.
//  Copyright (c) 2014 Haneke. All rights reserved.
//

import Foundation

public class DiskCache {
    
    public class func basePath() -> String {
        let cachesPath = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.cachesDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)[0]
        let hanekePathComponent = HanekeGlobals.Domain
        let basePath = (cachesPath as NSString).appendingPathComponent(hanekePathComponent)
        // TODO: Do not recaculate basePath value
        return basePath
    }
    
    public let path: String

    public var size : UInt64 = 0

    public var capacity : UInt64 = 0 {
        didSet {
            self.cacheQueue.async(execute: {
                self.controlCapacity()
            })
        }
    }

    public lazy var cacheQueue : DispatchQueue = {
        let queueName = HanekeGlobals.Domain + "." + (self.path as NSString).lastPathComponent
        let cacheQueue = DispatchQueue(label: queueName, attributes: [])
        return cacheQueue
    }()
    
    public init(path: String, capacity: UInt64 = UINT64_MAX) {
        self.path = path
        self.capacity = capacity
        self.cacheQueue.async(execute: {
            self.calculateSize()
            self.controlCapacity()
        })
    }
    
    public func setData( _ getData: @autoclosure(escaping) () -> Data?, key: String) {
        cacheQueue.async(execute: {
            if let data = getData() {
                self.setDataSync(data, key: key)
            } else {
                Log.error("Failed to get data for key \(key)")
            }
        })
    }
    
    public func fetchData(key: String, failure fail: ((NSError?) -> ())? = nil, success succeed: (Data) -> ()) {
        cacheQueue.async {
            let path = self.pathForKey(key)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: NSData.ReadingOptions())
                DispatchQueue.main.async {
                    succeed(data)
                }
                let _ = self.updateDiskAccessDateAtPath(path)
            } catch {
                if let block = fail {
                    DispatchQueue.main.async {
                        block(error as NSError)
                    }
                }
            }
        }
    }

    public func removeData(_ key: String) {
        cacheQueue.async(execute: {
            let path = self.pathForKey(key)
            self.removeFileAtPath(path)
        })
    }
    
    public func removeAllData(_ completion: (() -> ())? = nil) {
        let fileManager = FileManager.default
        let cachePath = self.path
        cacheQueue.async(execute: {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: cachePath)
                for pathComponent in contents {
                    let path = (cachePath as NSString).appendingPathComponent(pathComponent)
                    do {
                        try fileManager.removeItem(atPath: path)
                    } catch {
                        Log.error("Failed to remove path \(path)", error as NSError)
                    }
                }
                self.calculateSize()
            } catch {
                Log.error("Failed to list directory", error as NSError)
            }
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        })
    }

    public func updateAccessDate( _ getData: @autoclosure(escaping) () -> Data?, key: String) {
        cacheQueue.async(execute: {
            let path = self.pathForKey(key)
            let fileManager = FileManager.default
            if (!(fileManager.fileExists(atPath: path) && self.updateDiskAccessDateAtPath(path))){
                if let data = getData() {
                    self.setDataSync(data, key: key)
                } else {
                    Log.error("Failed to get data for key \(key)")
                }
            }
        })
    }

    public func pathForKey(_ key: String) -> String {
        let escapedFilename = key.escapedFilename()
        let filename = escapedFilename.characters.count < Int(NAME_MAX) ? escapedFilename : key.MD5Filename()
        let keyPath = (self.path as NSString).appendingPathComponent(filename)
        return keyPath
    }
    
    // MARK: Private
    
    private func calculateSize() {
        let fileManager = FileManager.default
        size = 0
        let cachePath = self.path
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: cachePath)
            for pathComponent in contents {
                let path = (cachePath as NSString).appendingPathComponent(pathComponent)
                do {
                    let attributes : NSDictionary = try fileManager.attributesOfItem(atPath: path)
                    size += attributes.fileSize()
                } catch {
                    Log.error("Failed to read file size of \(path)", error as NSError)
                }
            }

        } catch {
            Log.error("Failed to list directory", error as NSError)
        }
    }
    
    private func controlCapacity() {
        if self.size <= self.capacity { return }
        
        let fileManager = FileManager.default
        let cachePath = self.path
        fileManager.enumerateContentsOfDirectoryAtPath(cachePath, orderedByProperty: URLResourceKey.contentModificationDateKey.rawValue, ascending: true) { (URL : Foundation.URL, _, stop : inout Bool) -> Void in
            
            let path = URL.path
			self.removeFileAtPath(path)

			stop = self.size <= self.capacity
        }
    }
    
    private func setDataSync(_ data: Data, key: String) {
        let path = self.pathForKey(key)
        let fileManager = FileManager.default
        let previousAttributes : NSDictionary? = try? fileManager.attributesOfItem(atPath: path)
        
        do {
            try data.write(to: URL(fileURLWithPath: path), options: NSData.WritingOptions.atomicWrite)
        } catch {
            Log.error("Failed to write key \(key)", error as NSError)
        }
        
        if let attributes = previousAttributes {
            substractSize(attributes.fileSize())
        }
        self.size += UInt64(data.count)
        self.controlCapacity()
    }
    
    private func updateDiskAccessDateAtPath(_ path: String) -> Bool {
        let fileManager = FileManager.default
        let now = Date()
        do {
            try fileManager.setAttributes([FileAttributeKey.modificationDate : now], ofItemAtPath: path)
            return true
        } catch {
            Log.error("Failed to update access date", error as NSError)
            return false
        }
    }
    
    private func removeFileAtPath(_ path: String) {
        let fileManager = FileManager.default
        do {
            let attributes : NSDictionary =  try fileManager.attributesOfItem(atPath: path)
            let fileSize = attributes.fileSize()
            do {
                try fileManager.removeItem(atPath: path)
                substractSize(fileSize)
            } catch {
                Log.error("Failed to remove file", error as NSError)
            }
        } catch {
            let castedError = error as NSError
            if isNoSuchFileError(castedError) {
                Log.debug("File not found", castedError)
            } else {
                Log.error("Failed to remove file", castedError)
            }
        }
    }

    private func substractSize(_ size : UInt64) {
        if (self.size >= size) {
            self.size -= size
        } else {
            Log.error("Disk cache size (\(self.size)) is smaller than size to substract (\(size))")
            self.size = 0
        }
    }
}

private func isNoSuchFileError(_ error : NSError?) -> Bool {
    if let error = error {
        return NSCocoaErrorDomain == error.domain && error.code == NSFileReadNoSuchFileError
    }
    return false
}
