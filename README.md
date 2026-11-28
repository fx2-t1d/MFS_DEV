# MFS

Project plan (epics, user stories, technical tasks): [docs/](docs/README.md).

A standalone SwiftUI iOS app with sections for **Manage**, **Food**, and **Evaluate**. The Food Scan screen opens the camera, captures a photo when Scan is tapped, detects a barcode with Apple Vision, and looks up nutrition from the Open Food Facts v3 API. Barcode results show nutrition for one serving and the whole package with an Open Food Facts attribution link.

Open `MFS.xcodeproj`, select the MFS scheme, choose an iOS Simulator, and run. The shared `MFSTests` scheme includes a fixture-based scan test using `IMG_0270.HEIC` and a stubbed Open Food Facts response.

## Units and notation

Use the same notation in the app, code comments, docs and conversation:

| Quantity | Write | Example |
|---|---|---|
| Carbohydrate grams | `c` (not g) | 40 c |
| Protein grams | `p` (not g) | 8 p |
| Glucose | `mg/dl` | 120 mg/dl |
| Insulin | `units` or `u` | 4.8 u, 0.9 u/h |

Derived units follow the same letters: carb ratio is `c per u`, sensitivity is `mg/dl per u`. Fat and fiber grams stay `g`.

## Loop and LoopKit compatibility

All conversions live in `Sources/LoopKitBridge.swift` (the only file that maps between MFS and LoopKit types); the maths is in LoopKit-free files so tests cover it.

| Direction | Rule |
|---|---|
| CGM sample in | `NewGlucoseSample` quantity is read as mg/dl; readings go back out with sync identifier `mfs-glucose-<epoch>` |
| Profile out | Basal (u/h), sensitivity (mg/dl per u), carb ratio (c per u), target (range with equal ends) become Loop daily schedules; a midnight item carries the wrap-around value because Loop and pump schedules start at 0:00. nil if any time frame lacks the value |
| Profile in | Sensitivity converted to mg/dl, target range becomes its midpoint; time frames start at every change in any schedule |
| Pump events in | `NewPumpEvent.dose` is kept (bolus u, temp basal u/h and end time); older saved history without doses still loads |
| Insulin on board | Same exponential model as LoopKit (6 h, 75 min peak, 10 min delay). Boluses only; scheduled basal is not netted out |

MFS stays read-only toward the pump: no delivery commands are sent (see `docs/REMOTE_CONTROL_POLICY.md`). Not yet handled: mmol/L display, time zones other than the device's, 0.05 u pump rounding of imported schedules.

## Local Tidepool nutrition mapping

Verified 2026-09-27 against Tidepool's authoritative [Food documentation](https://tidepool.redocly.app/docs/device-data/data-types/food) and [API schema repository](https://github.com/tidepool-org/TidepoolApi/tree/89007e44d8d03bacdb7f74c454cb8bebbc9889f5). Schema files: `reference/common/models/nutrition.v1.yaml`, `energy/kilocalories.v1.yaml`, `reference/data/models/food/food.v1.yaml`, and `reference/data/models/amount.v1.yaml`.

`TidepoolNutritionMapper.map(product, consumedGrams: ...)` creates an Encodable **nutrition fragment**, with local issues and consumed mass. It does not create a complete food event, authenticate, or send data. The scanner retains unrounded numeric OFF `_100g` values separately from display strings. Callers must confirm the source is mass-based per 100 g (not per 100 ml), and explicitly supply consumed grams; the free-text serving size is not parsed. Accept invokes the mapper through a local preparation boundary for gram-based servings.

| MFS field | Tidepool nutrition path | Rule |
| --- | --- | --- |
| Calories (`energy-kcal`) | `energy.value`, units `kilocalories` | Scale by consumed grams / 100; range 0–10000 |
| Total fat | `fat.total`, units `grams` | Scale; range 0–1000 |
| Protein | `protein.total`, units `grams` | Scale; range 0–1000 |
| Carbohydrates | `carbohydrate.total` | MFS treats source as total including fiber under the requested net policy |
| Fiber / total sugars | `carbohydrate.dietaryFiber` / `sugars` | Only within a valid carbohydrate object |
| Confirmed net carbs | `carbohydrate.net`, units `grams` | Required by Tidepool if carbohydrate is present; defaults to total minus half fiber; user override supported |
| Saturated/trans fat, cholesterol, sodium, added sugars, vitamin D, calcium, iron, potassium, salt | No dedicated Nutrition fields | Retained locally, reported as unmapped |

All carbohydrate values are scaled and checked against 0–1000 grams. Default `.totalMinusHalfFiber` estimates net as total carbohydrate minus half dietary fiber, per the requested MFS policy. Both fields must be present and fiber must not exceed total. This is an app policy, not a Tidepool schema rule or a claim about every OFF label convention. `.confirmedTotalAndNet(netPer100g:)` accepts a user-edited net amount and confirms the total basis; overrides must be nonnegative and no greater than a known total. The override is per 100 g and scales with the consumed portion. `.unverified` omits the whole carbohydrate object. A future editing UI can pass the override; no nutrition-editing UI is added here. Missing values stay absent, zero stays zero, invalid/nonfinite/negative/out-of-range values are omitted with issues, and no values are clamped. Nutrition values describe the entire consumed portion, not concentration. Absorption duration is not inferred.

A complete Tidepool `food` record additionally requires brand, code, meal, name, and the common event context. Barcode/name/brand are candidate metadata, but optional brands, fallback names, missing meal/time, and string length limits (1–100) need validation before any future record builder. A scanned product is not evidence of consumption. This implementation deliberately exposes no food-record builder or upload endpoint. It does not repurpose insulin/bolus-calculator events or hide unsupported nutrients in arbitrary payload fields. Schema compatibility alone does not establish server acceptance, account permissions, or display support.

MFS remains standalone with Foundation/Vision and its existing OFF client only. Mapping tests cover portions, JSON keys/units, missing versus zero, unsupported fields, invalid quantities, schema limits, and unverified carbohydrates.

## Scan servings

The scan screen has an editable Number of servings field. It defaults to the whole package, calculated from OFF `product_quantity / serving_quantity` only when both are positive finite values with matching `g` or `ml` units. See the [OFF product schema](https://openfoodfacts.github.io/documentation/docs/Product-Opener/schemas/schemas/product/). Missing or incompatible quantities leave the field empty for manual entry. Fractional servings are supported. Accept requires a positive count and retains it for the current scan; editing clears the accepted state, and a new lookup clears the previous product and count. Barcode nutrition facts show only “1 serving” and “Per package,” calculated from the database’s normalized quantities and nutrient basis. The database’s per-100-g/ml values remain internal. Unknown serving or package quantities show dashes in the corresponding column. Changing the selected count does not change either reference column. No data is uploaded.

## Accept and Manage

Accept snapshots the scanned product and selected servings, prepares a local Tidepool nutrition fragment, and opens Manage, which shows name, servings, total and net carbs, protein and fat, with a pie chart of carbs, protein and fat grams. Missing source values show unavailable rather than zero. Accepted food and its draft currently live only for the app session and the latest acceptance replaces the prior one.

The **Manage** tab shows glucose from the hosted Dexcom G7 manager or LibreLoop's direct FreeStyle Libre 3 integration as a line with a trend arrow and a dashed forecast. LibreLoop pairs with the sensor over NFC and BLE without using Apple Health or the official Libre app. The forecast and meal display remain as documented below. The toolbar menu has a Connect devices sheet for Dexcom, LibreLoop and Omnipod DASH, plus Insulin profiles, Service connections, Biometric stream, User guide, Developer guide and About; Safety limits is still a disabled placeholder. The dose formula editor is under Dosing > Advanced. The Evaluate tab overlays measurements on one chart and has a Predictions section (see [docs/PREDICTION_API.md](docs/PREDICTION_API.md)). The dashed forecast on Manage is still the latest reading held flat. **History is kept across launches and new builds:** every glucose reading (all CGMs share one feed), Omnipod history events and the diagnostics log are saved as JSON files in the app's Application Support folder (`glucose-history.json`, `pump-history.json`, `diagnostics-log.json`; `Sources/HistoryStore.swift`). The app never deletes them. They survive updates only while the bundle ID stays the same and the app is installed over the old one; deleting the app removes them.


The Tidepool extension boundary prepares nutrition JSON only, with compatibility issues retained beside it. No uploads occur. Volume-based portions remain available to Manage but are not passed as grams to the local mapper. Missing event metadata and schema gaps still apply.

## Omnipod pairing

Connect devices can pair a new Omnipod DASH. This is the one exception to MFS being read-only toward the pump: pod activation (pair, prime, insert cannula) runs through OmnipodKit's own setup screens, and the pod then delivers a basal rate the user enters (one flat rate, no defaults, with maximum basal and maximum bolus) on its own. A pod pairs to one controller, so afterwards it no longer works with the Omnipod app or Loop. MFS code itself still never calls bolus, temp basal, suspend, resume or schedule-sync commands; `scripts/check_no_delivery_commands.sh` enforces that. A human safety review is required before release. Untested on a real pod.

## Patches to submodules

`scripts/apply_patches.sh` applies patches from `patches/` to pinned submodules after checkout; none are needed now, because the pinned G7SensorKit supports Dexcom Stelo (`DX01`) natively. Add an `apply` line to the script if one becomes necessary.

## Connecting devices

Nothing connects on its own. At launch MFS only resumes a G7 sensor that was already paired; with none paired it never scans, so it cannot attach to a nearby stranger's sensor. Pairing starts only when the user taps the pair button in Connect devices, and every device follows the same flow (`DeviceConnection`): check for an existing connection, disconnect it, then start the new one.

## Text food entry

Food > Text is a table: name, carbs and protein (required), fat and fiber (optional), in grams. Use Add row for more foods (swipe to delete). Each row has a Per serving checkbox: unchecked means grams for the whole amount eaten; checked means grams in one serving and the number of servings is required. Accept turns the whole table, with its optional camera photo, into one composite record in Manage; totals, the chart, the formula preview and the Tidepool draft all use the record as a whole (the photo stays on the device).

## Dose formula editor

Manage > Dosing > Advanced: dose formula edits toy model two: B(t) = b + C·(s * [A1·carbs·g_fast + A2·protein·g_hold])(t). Carbohydrate (net of fiber, chosen in the editor) drives a fast gamma component peaking at t1; protein drives a slow flat-top component centered at t2 (120 min hold and 60 min edge width are fixed); fat adds no glucose and only sets the time smear, whose width is σ minutes per gram of fat (no fat, no smear). Seven factors: three times (t1, t2, σ), three amplitudes (A1, A2, C) and an offset b. Defaults (A1 1, A2 1.5, C 0.5, t1 20, t2 240, σ 26.3, b 0) reproduce the reference curve (peak 0.0065 at 62 min, dip near 166, hump near 276) for 1 g each of carbs, protein and fat. The formula is saved on the device and previewed for the accepted food. The editor's Help button opens the full formulas and conversions, also in [docs/DOSE_FORMULA.md](docs/DOSE_FORMULA.md). Dosing builds a recommended bolus from the selected tab plus a glucose correction and insulin on board, shown with its parts and a list of inputs that are still placeholders (carb ratio and target in the insulin profile editor, current glucose, insulin on board, past meal results). `Sources/DoseRecommendation.swift` holds the recommenders and the input sources to plug into. Above Advanced, Dosing has three tabs: Meal specific (placeholder until Evaluate has results), Simple (a carbs number and a protein number in grams, protein defaulting to carbs ÷ 5; each is turned into units with the profile's carb ratio, and the expected rise is those units times sensitivity) and Experimental (a bolus for the first 120 minutes of B(t) plus an enhanced basal rate for the tail, and the expected rise as the area of B(t), using the active profile's sensitivity; display only). The formula is not yet used for the forecast. The glucose chart scrolls sideways through history; the 1, 3, 6, 12, 24 buttons under it set the visible hours, and a translucent black dot marks the meal time. The Evaluate tab overlays glucose, insulin parts (on board, bolus, basal; no data until pump history records amounts) and Apple Health biometrics, each with a checkbox.

## Insulin profiles and service connections

Manage toolbar menu (also: Connect devices, User guide, Developer guide, About):

- **Insulin profiles**: one Main profile plus any number of alternatives (for example "Sick"). Each profile has time frames (6am-11am, 11am-4pm, ...), each with basal (units/hour) and sensitivity (mg/dl one unit lowers glucose). Alternatives are selected by hand with Use / Back to main and stay in effect until changed. `ProfileSwitchHook` is the extension point for automatic switching; none are registered, and a manual choice is never overridden by a hook. No default values are supplied.
- **Service connections**: connection details only, no data format. A service has a name, https address and one of: none, shared secret in a header (Nightscout preset: `api-secret`, optionally SHA-1 hashed), bearer token, or a client certificate for mutual TLS (import a `.p12`). Secrets and certificates are stored in the Keychain.
- **Apple Health** (read only): pulse rate, sleep and heart rate variability. This needs the HealthKit capability on the App ID and provisioning profile (`Sources/MFS.entitlements`). The app never writes to Apple Health (`requestAuthorization(toShare: [])`), but the bundled LoopKit contains HealthKit write code, so App Store Connect requires `NSHealthUpdateUsageDescription` in addition to `NSHealthShareUsageDescription`; both are set in the build settings.
- **Biometrics to DigitalMe**: heart rate (`heartRate`, bpm), heart rate variability (`heartRateVariability`, ms) and nightly sleep (`sleepDuration`, minutes) are mapped to the Tidepool-format `biometric` type defined in [TidepoolApi_extended](https://github.com/fx2-t1d/TidepoolApi_extended) and sent with `DigitalMeUploadClient.upload(records:to: .biometrics, ...)` to DigitalMe's `POST /biometrics/upload`, over the same mTLS connection and security checks as other uploads. A biometric is a measurement of the body's state at a point in time; glucose is never sent this way and keeps `cbg`/`smbg`. `HealthBiometricReader` reads only new samples (anchored queries); save the returned `BiometricBatch.pendingState` only after the upload succeeds.
- **Biometric stream** (Manage > menu > Biometric stream): approve once which items to send (pulse rate, heart rate variability, sleep) and which DigitalMe connection receives them. From then on every new glucose reading triggers a send of whatever is new for the approved items: heart rate and HRV can be none, one or several samples per reading; a sleep night goes out once, after it has ended. The approval is standing consent: it stays until you turn items off or choose Stop (which also forgets what was sent). Biometrics are never sent below TLS with a verified server, whatever the connection's own setting says. Each send re-checks that. A connection that still meets the required level (at least TLS) is accepted even if it changed; a changed certificate, level or server mode is written, time-tagged, to the connection's security history for audit. The stream pauses only when security falls below the required level or DigitalMe refuses the upload. DigitalMe holds records it cannot validate for review instead of refusing them. MFS accepts no remote commands (see `docs/REMOTE_CONTROL_POLICY.md`). Network failures keep it running: Health anchors are saved only after DigitalMe accepts a batch, so the next reading repeats the send (DigitalMe ignores duplicates). Backlogs go out in batches of 500. It only runs while the app is running, and needs Apple Health access (Service connections > Connect Apple Health) and an imported client certificate. Glucose itself is not streamed by this feature.

## Connect devices layout

Connect devices opens **Sensors** and **Pumps** submenus. Each device (`DeviceKind` in `Sources/DeviceCatalog.swift`) has its own screen with its own guidance and pairing flow (`DevicePairingView`). Libre 3 pairing reads the sensor over NFC, which needs the "NFC Tag Reading" capability on the App ID and in the provisioning profile (`com.apple.developer.nfc.readersession.formats` in `Sources/MFS.entitlements`).

## Troubleshooting

Connect devices > Sensors > FreeStyle Libre 3 > Troubleshooting shows the paired sensor's saved state (pair time, first and latest reading, warm-up), counters for what reached MFS (callbacks, samples received, samples added to the chart, last result), and two logs: MFS's own (`DiagnosticsLog`, every reading result, error, status change and device-log message from the CGM manager) and LibreLoop's. Share report exports everything as text. LibreLoop also keeps a file at Documents/libreloop/log.txt. Every host built on `CGMHostBase` (G7, Libre 3) feeds the MFS log.

## Predictions and models

Evaluate > Predictions compares what swappable models predicted at a chosen moment with what glucose did, on a dual-axis chart. Models: Descartes1 (latest reading plus the dose formula's food effect), Flat, and the bundled Oref0 and Oref1 (`tools/oref`, MIT). Contract, build steps and limits: [docs/PREDICTION_API.md](docs/PREDICTION_API.md).
