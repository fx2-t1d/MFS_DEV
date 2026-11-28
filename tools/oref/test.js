// Runs the built bundle the way JavaScriptCore does (no Node globals) and checks both variants.
// Usage: node tools/oref/test.js   (after build.sh)
const vm = require('vm'), fs = require('fs'), path = require('path'), assert = require('assert');
const source = fs.readFileSync(path.join(__dirname, '../../Sources/Resources/oref.bundle.js'), 'utf8');
const t = 1700000000;

function run(variant, { rising = true, carbs = 40, foodAge = 1800 } = {}) {
  const context = vm.createContext({});
  vm.runInContext(source, context);
  const readings = Array.from({ length: 24 }, (_, i) => ({ t: t - (23 - i) * 300, mgdl: 100 + (rising ? i * 3 : 0) }));
  context.request = JSON.stringify({
    version: 1, time: t, horizon: 7200, step: 300, readings,
    foods: carbs ? [{ t: t - foodAge, carbs, protein: 10, fat: 5 }] : [],
    doses: [{ t: t - 1500, units: 3 }],
    settings: { isf: 50, carbRatio: 10, basal: 1, target: 100, dia: 6 }, options: { variant }
  });
  return JSON.parse(vm.runInContext('predict(request)', context));
}

const names = (r) => r.series.map((s) => s.name);
const oref0 = run('oref0');
assert.deepStrictEqual(names(oref0), ['IOB', 'COB', 'ZT'], 'oref0 has no UAM curve');
const oref1 = run('oref1');
assert.deepStrictEqual(names(oref1), ['IOB', 'COB', 'UAM', 'ZT'], 'oref1 adds UAM');
for (const s of oref1.series) {
  assert.strictEqual(s.points[0].t, t + 300, 'predictions start one step after the latest reading');
  assert.ok(s.points.every((p) => p.t <= t + 7200 && Number.isFinite(p.mgdl)));
}
assert.ok(run('oref0', { rising: false }).error, 'flat data is reported, not drawn');
// Food entered now (at the latest reading) must change the prediction.
const final = (r, name) => r.series.find((x) => x.name === name).points.slice(-1)[0].mgdl;
for (const variant of ['oref0', 'oref1']) {
  const withFood = run(variant, { foodAge: 0 });
  const without = run(variant, { carbs: 0 });
  assert.ok(!withFood.error, withFood.error);
  assert.notStrictEqual(final(withFood, 'COB'), final(without, 'IOB'), variant + ': food changes the COB curve');
  assert.ok(final(withFood, 'COB') > final(without, 'IOB'), variant + ': 40 c raises glucose above the no-food curve');
}
console.log('oref bundle OK');
