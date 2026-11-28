# User guide

MFS shows your glucose, helps you log food, and shows what models predict will happen. It is read-only toward your pump: it never sends delivery commands.

## Units

Carbohydrates are written in c, protein in p, glucose in mg/dl, insulin in units or u. Fat and fiber stay in g.

## The three tabs

- Manage: your glucose trend, the accepted food, dosing, and the menu (the circle with dots, top right) for devices, profiles, services and help.
- Food: scan a barcode or enter a food by hand, then tap Accept.
- Evaluate: charts of your data and the Predictions view.

## Getting started

- Open the menu on Manage, choose Connect devices, and pair your CGM and pump.
- Choose Insulin profiles and enter sensitivity (mg/dl per u), carb ratio (c per u), basal (u/h) and target (mg/dl). Oref0 and Oref1 use these, so enter them for meaningful predictions.
- Glucose readings appear on Manage and Evaluate once the CGM is connected.

## Logging food

- Scan a barcode or use manual entry on the Food tab, check the amounts, and tap Accept.
- The accepted food appears on Manage. Its meal time follows the latest glucose reading; drag the marker on the glucose chart to change it.
- The accepted food is used by Predictions right away.

## Predictions (Evaluate tab)

- Models: choose one or more. Descartes1 is the app's own model and uses the dose formula for food. Flat holds the latest reading steady. Oref0 and Oref1 are the open-source OpenAPS models. Choosing several draws them together so you can compare.
- Axes: the chart has a left and a right scale. Each kind of data (glucose, insulin, carbohydrates) goes on either side; glucose is on the right by default. Each side is Auto or Fixed (you set the minimum and maximum). Reset axes restores the defaults.
- Predicted at: the slider picks the moment. A model sees only what was known then. The dashed line is that moment, solid blue is what was known, green is what actually happened, and dashed colors are predictions.
- Accuracy: under the chart each prediction shows its average error and RMS error in mg/dl against later readings. It says so when there are none yet.
- Food: when you accept a food, the slider jumps to now and each model shows what it expects. A model without food math will not change.
- Failures: if a model cannot run (for example Oref with perfectly flat glucose data) the reason is shown in red instead of a curve.

## Limits

- Predictions are for viewing and comparing models. They are not dosing advice. Check any dose with your care team.
- Descartes1 is a hand-shaped toy model that has not been fitted to data. Insulin does not yet change its curve.
- Oref COB curves need carbs; Oref does not yet receive temp basal history.
