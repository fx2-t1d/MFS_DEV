# Developer guide

Technical manual for MFS (SwiftUI, iOS 17.6). Source of truth for the prediction contract is docs/PREDICTION_API.md in the repository; this guide summarizes it.

## Layout

- Sources/MFSApp.swift: app entry, tabs, Manage, stores injected as environment objects.
- Sources/GlucoseFeed.swift and the CGM hosts: glucose readings.
- Sources/InsulinProfiles.swift, InsulinModel.swift, LoopKitBridge.swift: profiles, insulin on board, the only file that maps to LoopKit types.
- Sources/DoseFormula.swift: toy dose formula B(t).
- Sources/PredictionModel.swift: the model API. Foundation only, so it is testable on Linux.
- Sources/PredictionAxes.swift: axis and layer layout logic. Foundation only.
- Sources/PredictionView.swift: SwiftUI chart, models menu, axes sheet.
- Sources/DescartesModel.swift: Descartes1 and Flat.
- Sources/OrefPredictionModels.swift: Oref0 and Oref1 registration and the standard registry.
- tools/oref: build script and adapter for the oref bundle.

## Prediction model API

- A model conforms to PredictionModel: an id, a display name, and predict(context, horizon, step) returning named series of points.
- ForecastContext carries readings, foods and doses. The evaluator removes everything after the prediction time before calling a model, so a model cannot see the future.
- PredictionModelRegistry holds the models the UI offers. Registering a model with an existing id replaces it. The view needs no change to show a new model.
- PredictionEvaluator.evaluate scores each series against later readings (mean absolute and RMS error) and reports a failure per model instead of throwing.

## Script models

ScriptPredictionModel runs any model written outside Swift. It sends a JSON request and reads a JSON reply, versioned with a version field.

- Request: time (seconds), horizon, step, readings, foods, doses, optional settings (isf, carbRatio, basal, target, dia, maxIOB) and options (free-form strings).
- Reply: either series (each with a name and points of t and mgdl, optionally lower and upper) or error.
- Transports: JavaScriptPredictionTransport runs a script in JavaScriptCore, which works on iOS. CommandPredictionTransport runs an executable and is for macOS, Linux and tests; wrappers must exec so a timeout kills the model.
- To add a model, write a script or command that follows the contract and register a ScriptPredictionModel with its own id and name.

## Oref0 and Oref1

- openaps/oref0 (MIT) is bundled unchanged at a pinned commit. tools/oref/adapter.js converts the contract to oref inputs and predBGs to the curves IOB, COB, UAM and ZT.
- Oref0 and Oref1 differ only by options.variant. Oref1 enables SMB and unannounced meal detection.
- Rebuild with tools/oref/build.sh (needs node and git) and check with node tools/oref/test.js. To update, change the pinned commit in build.sh, rebuild and commit Sources/Resources/oref.bundle.js.
- Known limits: perfectly flat glucose is an oref error, ZT uses the profile basal, temp basal history is not passed, autosens is off.

## Descartes1

- Reads B(t) from DoseFormula as mg/dl of rise per minute. The effect at a time is the running total since eating, minus the total at the latest reading, which is already in that reading.
- Fiber and insulin are not used yet. Add them by extending DescartesFoodInfluence or supplying a doseInfluence to GlucoseForecaster.

## Chart axes

SwiftUI Charts has one y scale. Each layer is normalized to 0...1 using the axis of its side, and the leading and trailing AxisMarks label that range with real values. PredictionChartConfig stores sides, ranges and selected models, saved in UserDefaults under MFS.PredictionChartConfig.

## Build and test

- Open MFS.xcodeproj, scheme MFS to run, MFSTests to test.
- New source files must be added to project.pbxproj by hand, including the MFSTests target when tests compile them directly.
- Foundation-only files and their tests run with swift test on Linux using a small package that copies those files.
- Units: c for carbohydrates, p for protein, mg/dl, u for insulin.

## Help screens

Help text lives in Sources/Resources/UserGuide.md and DeveloperGuide.md and is shown by HelpView. The About screen is in HelpView.swift; fill in the license and developer details there.
