// The module's resources as files. Skip packages them as APK assets under
// piru/module/Resources, which no file API opens, while the shared code hands resource URLs
// to GRDB (the substance catalog) and to Data(contentsOf:). substitutions.txt points
// `Bundle.main.url(forResource:withExtension:)` here.

#if os(Android)
    import Android
    import AndroidAssetManager
    import Foundation
    import SkipAndroidBridge
    import SkipBridge
    @preconcurrency import SwiftJNI
    import Synchronization

    nonisolated enum AndroidResources {
        /// The module's resource bundle, backed by the APK assets. SwiftPM's generated
        /// `Bundle.module` builds a Darwin-style `.bundle` URL that no Android bundle answers;
        /// Skip's path initializer maps `<main bundle>/<package>_Piru.resources` to the module.
        static let bundle: Bundle = AndroidBundle(
            path: AndroidBundle.main.bundlePath + "/piru-android_Piru.resources", moduleName: "Piru",
        ) {
            try! AnyDynamicObject(className: "piru.module._ModuleBundleAccessor_Piru").moduleBundle!
        } ?? .main

        /// The substance catalog's file name, as the shared code asks for it.
        static let catalogFile = "piru-substances.sqlite"

        /// Where Skip puts the module's resources, and the folders stage.py copies whole (on iOS
        /// their files sit at the bundle root).
        private static let assetDirectory = "piru/module/Resources"
        private static let subdirectories = ["", "Licenses/"]
        /// How much of an asset one read holds in memory.
        private static let chunkSize = 1 << 20

        /// Why a resource could not be copied out of the APK.
        enum CopyFailure: Error, Equatable {
            /// The APK holds no such resource.
            case missing
            /// The copy needs `needed` bytes of free space, and the volume has less.
            case insufficientSpace(needed: Int64)
            /// Reading the asset or writing the copy failed; the system's description of why.
            case failed(String)
        }

        /// The resource's copy as a file, or nil when it cannot be made.
        static func url(forResource name: String?, withExtension ext: String?) -> URL? {
            guard let name else { return nil }
            return try? copiedURL(for: ext.map { "\(name).\($0)" } ?? name).get()
        }

        /// The resource's copy in no_backup/Resources, made on first use and again whenever the
        /// APK's resources change: `PiruResourceStamp` hashes every staged resource, so a rebuilt
        /// catalog of the same size still replaces the old copy.
        static func copiedURL(for file: String) -> Result<URL, CopyFailure> {
            verified.withLock { copies in
                if let url = copies[file] { return .success(url) }
                let result = copy(file)
                if case let .success(url) = result { copies[file] = url }
                return result
            }
        }

        /// Copies confirmed current this process, by file name.
        private static let verified = Mutex<[String: URL]>([:])

        /// Streams the asset into a staging file beside the copy, then renames it over the copy,
        /// so the copy on disk is always whole: the previous one stays until its replacement is in
        /// place, and its stamp names the resources it came from only once the rename succeeds.
        private static func copy(_ file: String) -> Result<URL, CopyFailure> {
            guard let manager = assetManager, let asset = subdirectories.lazy.compactMap({
                manager.open(from: "\(assetDirectory)/\($0)\(file)", mode: .streaming)
            }).first else { return .failure(.missing) }
            defer { asset.close() }

            let fileManager = FileManager.default
            let destination = folder.appendingPathComponent(file)
            let stampFile = folder.appendingPathComponent(".\(file).stamp")
            let staging = folder.appendingPathComponent(".\(file).partial")
            if fileManager.fileExists(atPath: destination.path),
               (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp {
                return .success(destination)
            }

            let needed = asset.length
            try? fileManager.removeItem(at: staging)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                if let free = freeSpace(at: folder), free < needed {
                    return .failure(.insufficientSpace(needed: needed))
                }
                try write(asset, to: staging)
                guard rename(staging.path, destination.path) == 0 else { throw WriteError.system(errno) }
                syncDirectory(folder)
                try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
            } catch {
                try? fileManager.removeItem(at: staging)
                switch error {
                case let WriteError.system(code) where code == ENOSPC || code == EDQUOT:
                    return .failure(.insufficientSpace(needed: needed))
                case let error as CocoaError where error.code == .fileWriteOutOfSpace:
                    return .failure(.insufficientSpace(needed: needed))
                case let WriteError.system(code):
                    return .failure(.failed(String(cString: strerror(code))))
                case WriteError.unreadable:
                    return .failure(.failed("asset read failed"))
                default:
                    return .failure(.failed(error.localizedDescription))
                }
            }
            if fileManager.fileExists(atPath: legacyFolder.path) {
                try? fileManager.removeItem(at: legacyFolder)
            }
            return .success(destination)
        }

        private enum WriteError: Error {
            case system(Int32)
            case unreadable
        }

        /// Writes the asset to `file` a chunk at a time and flushes it to storage.
        private static func write(_ asset: AndroidAssetManager.Asset, to file: URL) throws {
            let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw WriteError.system(errno) }
            defer { close(descriptor) }
            while asset.remainingLength > 0 {
                // A read sized past the remaining bytes comes back padded to that size.
                let size = min(chunkSize, Int(asset.remainingLength))
                guard let chunk = asset.read(size: size), !chunk.isEmpty else { throw WriteError.unreadable }
                try chunk.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    guard let base = buffer.baseAddress else { return }
                    var offset = 0
                    while offset < buffer.count {
                        let written = Android.write(descriptor, base + offset, buffer.count - offset)
                        if written < 0 {
                            if errno == EINTR { continue }
                            throw WriteError.system(errno)
                        }
                        offset += written
                    }
                }
            }
            guard fsync(descriptor) == 0 else { throw WriteError.system(errno) }
        }

        /// Flushes the folder's entries, so the rename survives a power loss with the file.
        private static func syncDirectory(_ folder: URL) {
            let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            _ = fsync(descriptor)
            close(descriptor)
        }

        /// The bytes an app may still write on the volume holding `url`.
        private static func freeSpace(at url: URL) -> Int64? {
            var info = statvfs()
            guard statvfs(url.path, &info) == 0 else { return nil }
            return Int64(info.f_bavail) * Int64(info.f_frsize)
        }

        /// The resource stamp of this APK.
        private static let stamp = AndroidInfoPlist.object(forInfoDictionaryKey: "PiruResourceStamp") as? String ?? ""

        /// no_backup/Resources. The OS never purges no_backup, where it may empty Caches whenever
        /// storage runs low; Application Support stands in if Android does not name the folder.
        private static let folder: URL = {
            let context = ProcessInfo.processInfo.dynamicAndroidContext()
            let base: URL = if let directory: AnyDynamicObject = try? context.getNoBackupFilesDir(),
                               let path: String = try? directory.getAbsolutePath() {
                URL(fileURLWithPath: path, isDirectory: true)
            } else {
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            }
            return base.appendingPathComponent("Resources", isDirectory: true)
        }()

        /// Caches/Resources, where earlier builds copied the resources; removed once a copy
        /// lands in ``folder``.
        private static let legacyFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resources", isDirectory: true)

        private static let assetManager: AndroidAssetManager? = {
            let context = ProcessInfo.processInfo.dynamicAndroidContext()
            guard let contextObject = context.toJavaObject(options: []),
                  let contextClass = try? JClass(name: "android/content/Context"),
                  let getResources = contextClass.getMethodID(name: "getResources", sig: "()Landroid/content/res/Resources;"),
                  let resources: JavaObjectPointer = try? JObject(contextObject).call(method: getResources, options: [], args: []),
                  let resourcesClass = try? JClass(name: "android/content/res/Resources"),
                  let getAssets = resourcesClass.getMethodID(name: "getAssets", sig: "()Landroid/content/res/AssetManager;"),
                  let assets: JavaObjectPointer = try? JObject(resources).call(method: getAssets, options: [], args: [])
            else { return nil }
            return JNI.jni.withEnv { _, env in AndroidAssetManager(env: env, peer: assets) }
        }()
    }
#endif
