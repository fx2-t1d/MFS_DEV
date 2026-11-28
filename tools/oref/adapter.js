'use strict';
// Adapts the MFS prediction API (docs/PREDICTION_API.md) to openaps/oref0's determine-basal.
// Bundled with oref0 into Sources/Resources/oref.bundle.js by tools/oref/build.sh.
// options.variant "oref0" = no SMB/UAM; "oref1" = SMB and unannounced-meal detection enabled.

var determineBasal = require('oref0/lib/determine-basal/determine-basal');
var getLastGlucose = require('oref0/lib/glucose-get-last');
var iobTotal = require('oref0/lib/iob/total');
var iobCalculate = require('oref0/lib/iob/calculate');
var mealTotal = require('oref0/lib/meal/total');
var tempBasalFunctions = require('oref0/lib/basal-set-temp');

var MIN = 60 * 1000;

// oref0 reads entry times as strings in the runtime's local time zone, matching how it parses them back.
function localTime(ms) {
  var d = new Date(ms), p = function (n) { return (n < 10 ? '0' : '') + n; };
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + 'T' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function buildProfile(settings, variant) {
  var basal = settings.basal || 1;
  var target = settings.target || 100;
  var profile = {
    // The app models insulin like Loop: rapid-acting curve, 75 min peak, 6 h.
    curve: 'rapid-acting', dia: settings.dia || 6,
    sens: settings.isf || 50, carb_ratio: settings.carbRatio || 10,
    current_basal: basal, max_daily_basal: basal, max_basal: Math.max(basal * 4, 1),
    min_bg: target, max_bg: target, type: 'current', out_units: 'mg/dL',
    max_iob: settings.maxIOB || 3, min_5m_carbimpact: 8, maxCOB: 120,
    carbsReqThreshold: 1, remainingCarbsCap: 90, remainingCarbsFraction: 1,
    autosens_max: 1.2, autosens_min: 0.7, bolus_increment: 0.1, model: '554',
    basalprofile: [{ i: 0, start: '00:00:00', rate: basal, minutes: 0 }]
  };
  if (variant === 'oref1') {
    profile.enableUAM = true;
    profile.enableSMB_always = true;
    profile.maxSMBBasalMinutes = 30;
    profile.maxUAMSMBBasalMinutes = 30;
    profile.SMBInterval = 3;
    profile.allowSMB_with_high_temptarget = false;
  }
  return profile;
}

function buildIob(request, profile, clock) {
  var treatments = request.doses.map(function (d) {
    return { insulin: d.units, date: d.t * 1000, started_at: new Date(d.t * 1000) };
  });
  // Zero-temp insulin: scheduled basal withheld for the next 4 h, as oref0 does for its ZT curve.
  var zeroTemp = treatments.slice();
  for (var m = 0; m < 240; m += 5) {
    zeroTemp.push({ insulin: -profile.current_basal * 5 / 60, date: clock.getTime() + m * MIN });
  }
  var array = [];
  for (var i = 0; i < 240; i += 5) {
    var t = new Date(clock.getTime() + i * MIN);
    var now = iobTotal({ treatments: treatments, profile: profile, calculate: iobCalculate }, t);
    now.iobWithZeroTemp = iobTotal({ treatments: zeroTemp, profile: profile, calculate: iobCalculate }, t);
    array.push(now);
  }
  var lastBolus = treatments.reduce(function (a, b) { return Math.max(a, b.date); }, 0);
  array[0].lastBolusTime = lastBolus;
  return array;
}

function buildMeal(request, profile, glucose, clock) {
  var treatments = request.foods.filter(function (f) { return f.carbs >= 1; }).map(function (f) {
    var when = new Date(f.t * 1000).toISOString();
    return { carbs: f.carbs, nsCarbs: f.carbs, timestamp: when, created_at: when };
  });
  try {
    return mealTotal({
      treatments: treatments, profile: profile, pumphistory: [], glucose: glucose,
      basalprofile: profile.basalprofile
    }, clock);
  } catch (e) {
    // Fall back to the carbs alone, without absorption detection.
    var total = treatments.reduce(function (a, b) { return a + b.carbs; }, 0);
    return { carbs: total, mealCOB: total, currentDeviation: 0, maxDeviation: 0, minDeviation: 0,
             slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0, allDeviations: [0, 0, 0, 0, 0],
             lastCarbTime: treatments.length ? Date.parse(treatments[0].timestamp) : 0 };
  }
}

function series(name, values, start, step) {
  // oref's arrays start with the current glucose; the first prediction is one step later.
  return {
    name: name,
    points: values.slice(1).map(function (v, i) { return { t: start + (i + 1) * step, mgdl: v }; })
  };
}

function predict(requestJSON) {
  try {
    var request = JSON.parse(requestJSON);
    var variant = (request.options && request.options.variant) || 'oref0';
    var clock = new Date(request.time * 1000);
    var profile = buildProfile(request.settings || {}, variant);

    var glucose = request.readings.slice().sort(function (a, b) { return b.t - a.t; })
      .map(function (r) { return { date: r.t * 1000, glucose: r.mgdl, device: 'mfs', display_time: localTime(r.t * 1000), dateString: new Date(r.t * 1000).toISOString() }; });
    if (glucose.length < 2) { return JSON.stringify({ error: 'oref needs at least two glucose readings' }); }
    var status = getLastGlucose(glucose.map(function (g) { return Object.assign({}, g); }));

    var iob = buildIob(request, profile, clock);
    var meal = buildMeal(request, profile, glucose, clock);
    var result = determineBasal(status, { duration: 0, rate: 0, temp: 'absolute' }, iob, profile,
      { ratio: 1 }, meal, tempBasalFunctions, variant === 'oref1', undefined, clock);

    var pred = result && result.predBGs;
    if (!pred) { return JSON.stringify({ error: (result && (result.error || result.reason)) || 'oref0 returned no predictions' }); }

    var step = 300, start = request.time, out = [];
    ['IOB', 'COB', 'UAM', 'ZT'].forEach(function (key) {
      if (pred[key] && pred[key].length > 1) { out.push(series(key, pred[key], start, step)); }
    });
    var horizonEnd = start + request.horizon;
    out.forEach(function (s) { s.points = s.points.filter(function (p) { return p.t <= horizonEnd; }); });
    out = out.filter(function (s) { return s.points.length > 0; });
    return JSON.stringify({ version: 1, series: out });
  } catch (e) {
    return JSON.stringify({ error: String(e && e.message || e) });
  }
}

if (typeof globalThis !== 'undefined') { globalThis.predict = predict; }
module.exports = { predict: predict };
