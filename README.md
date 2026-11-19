# MFS

Project plan (epics, user stories, technical tasks): [docs/](docs/README.md).

A standalone SwiftUI iOS app with sections for **Manage**, **Food**, and **Evaluate**. The Food Scan screen opens the camera, captures a photo when Scan is tapped, detects a barcode with Apple Vision, and looks up nutrition from the Open Food Facts v3 API. Barcode results show nutrition for one serving and the whole package with an Open Food Facts attribution link.

Open `MFS.xcodeproj`, select the MFS scheme, choose an iOS Simulator, and run. The shared `MFSTests` scheme includes a fixture-based scan test using `IMG_0270.HEIC` and a stubbed Open Food Facts response.

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

The **Manage** tab shows glucose from the hosted Dexcom G7 manager as a line with a trend arrow and a dashed forecast. The forecast is the latest reading held flat plus the output of two `GlucoseInfluence` models (food and dose), both `NoInfluence` for now, so they change nothing. Attach real models through `ForecastContext` and `GlucoseForecaster` in `Sources/GlucoseForecast.swift`. After a food is accepted, a small macro pie chart sits on the line at the latest reading (now). Dragging it moves the meal time in 5-minute steps, earlier for food already eaten or later for a dose before eating; "Reset to now" returns it. The meal time is not yet sent anywhere. A footer shows the meal macros (carbohydrate, protein, fat) and below them the formula bolus for carbohydrate, the formula bolus for protein and the current basal; the bolus and basal values show "—" until the dose formula and pump data are connected. The toolbar menu has a working Connect devices sheet: it pairs a Dexcom G7, ONE+ or Stelo (no code needed; the app listens for a newly started sensor) and shows sensor status, expiry and last reading; it also activates and manages an Omnipod DASH pod (see below). Dose formulas opens the formula editor (below); safety limits is still a disabled placeholder. The Evaluate tab is unchanged.


The Tidepool extension boundary prepares nutrition JSON only, with compatibility issues retained beside it. No uploads occur. Volume-based portions remain available to Manage but are not passed as grams to the local mapper. Missing event metadata and schema gaps still apply.

## Omnipod pairing

Connect devices can pair a new Omnipod DASH. This is the one exception to MFS being read-only toward the pump: pod activation (pair, prime, insert cannula) runs through OmnipodKit's own setup screens, and the pod then delivers a basal rate the user enters (one flat rate, no defaults, with maximum basal and maximum bolus) on its own. A pod pairs to one controller, so afterwards it no longer works with the Omnipod app or Loop. MFS code itself still never calls bolus, temp basal, suspend, resume or schedule-sync commands; `scripts/check_no_delivery_commands.sh` enforces that. A human safety review is required before release. Untested on a real pod.

## Patches to submodules

`patches/` holds changes applied to pinned submodules by `scripts/apply_patches.sh`, which the build and test workflows run after checkout (run it locally after `git submodule update --init`). `G7SensorKit-stelo.patch` lets the G7 manager connect to Dexcom Stelo, which advertises as `DX01`; upstream rejected it as unmerged (LoopKit/G7SensorKit#30). Stelo is community-tested only and has no alerts through MFS. Remove the patch when upstream supports Stelo.

## Text food entry

Food > Text is a table: name, carbs and protein (required), fat and fiber (optional), in grams. Use Add row for more foods (swipe to delete). Each row has a Per serving checkbox: unchecked means grams for the whole amount eaten; checked means grams in one serving and the number of servings is required. Accept turns the whole table, with its optional camera photo, into one composite record in Manage; totals, the chart, the formula preview and the Tidepool draft all use the record as a whole (the photo stays on the device).

## Dose formula editor

Manage > menu > Dose formulas edits B(t) = x·c(t) + y·p(t) + z·f(t), the impact on blood glucose t minutes after eating. One row per nutrient: constant (x, y, z, any value), time function (constant, linear rise or decay, logarithmic rise or decay over a span in minutes), and an optional × G(t) multiplier using the glucose level. The carbohydrate row also chooses how fiber counts (total carbs, net with fiber ÷ 2, or net with all fiber). The formula is saved on the device and previewed for the accepted food. It is not yet used for the forecast or the footer's bolus values; the constants start at 0, so nothing is suggested until you set them.

## Insulin profiles and service connections

Manage toolbar menu:

- **Insulin profiles**: one Main profile plus any number of alternatives (for example "Sick"). Each profile has time frames (6am-11am, 11am-4pm, ...), each with basal (units/hour) and sensitivity (mg/dL one unit lowers glucose). Alternatives are selected by hand with Use / Back to main and stay in effect until changed. `ProfileSwitchHook` is the extension point for automatic switching; none are registered, and a manual choice is never overridden by a hook. No default values are supplied.
- **Service connections**: connection details only, no data format. A service has a name, https address and one of: none, shared secret in a header (Nightscout preset: `api-secret`, optionally SHA-1 hashed), bearer token, or a client certificate for mutual TLS (import a `.p12`). Secrets and certificates are stored in the Keychain.
- **Apple Health** (read only): pulse rate, sleep and heart rate variability. This needs the HealthKit capability on the App ID and provisioning profile (`Sources/MFS.entitlements`).
