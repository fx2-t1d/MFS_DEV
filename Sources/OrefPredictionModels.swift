import Foundation

/// A transport for a model whose runtime or script is missing; it reports why instead of failing silently.
struct UnavailableTransport: PredictionTransport {
    let reason: String
    func exchange(_ request: Data) throws -> Data { throw PredictionError.modelFailed(reason) }
}

/// oref0 and oref1 (openaps/oref0, MIT) run unchanged as a bundled script through the script API.
/// The script is built by tools/oref/build.sh into Resources/oref.bundle.js.
enum OrefPredictionModels {
    static let resourceName = "oref.bundle"

    static func transport(bundle: Bundle) -> PredictionTransport {
        #if canImport(JavaScriptCore)
        guard let url = bundle.url(forResource: resourceName, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return UnavailableTransport(reason: "oref.bundle.js is missing from the app. Run tools/oref/build.sh and add it to the MFS target.")
        }
        return JavaScriptPredictionTransport(source: source)
        #else
        return UnavailableTransport(reason: "oref needs JavaScriptCore, which is not available on this platform.")
        #endif
    }

    static func models(settings: PredictionWire.Settings?, bundle: Bundle = .main) -> [PredictionModel] {
        let transport = transport(bundle: bundle)
        return [
            ScriptPredictionModel(id: "oref0", name: "Oref0", transport: transport, settings: settings, options: ["variant": "oref0"]),
            ScriptPredictionModel(id: "oref1", name: "Oref1", transport: transport, settings: settings, options: ["variant": "oref1"]),
        ]
    }
}

extension PredictionWire.Settings {
    init(segment: ProfileSegment) {
        self.init(isf: segment.sensitivityMgdlPerUnit, carbRatio: segment.carbRatioGramsPerUnit,
                  basal: segment.basalUnitsPerHour, target: segment.targetMgdl)
    }
}

extension PredictionModelRegistry {
    /// The app's own model (Descartes1) plus Oref0 and Oref1.
    static func standard(settings: PredictionWire.Settings?, bundle: Bundle = .main) -> PredictionModelRegistry {
        PredictionModelRegistry(models: [ForecasterPredictionModel(id: "descartes1", name: "Descartes1")]
            + OrefPredictionModels.models(settings: settings, bundle: bundle))
    }
}
