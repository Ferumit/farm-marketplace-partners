// createOrder with formats: a half or a whole carcass, the farm's paid cutting (priced per half) and
// delivery (its tariff for a city, or pickup) - every amount computed on the server - and the older
// share-count orders still working beside it.
//
// Runs against the local emulators under a demo- project id, so it can never touch production:
//   cd tests/functions && npm test
const path = require("path");
const fnModules = path.join(__dirname, "../../functions/node_modules");
const { initializeApp } = require(path.join(fnModules, "firebase-admin/lib/app/index.js"));
const { getFirestore } = require(path.join(fnModules, "firebase-admin/lib/firestore/index.js"));
const { getAuth } = require(path.join(fnModules, "firebase-admin/lib/auth/index.js"));

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("refusing to run outside the emulator");
  process.exit(2);
}

initializeApp({ projectId: "demo-et" });
const db = getFirestore();
const auth = getAuth();
const FN = "http://127.0.0.1:5001/demo-et/europe-west3/createOrder";

async function idTokenFor(uid, phone) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  const custom = await auth.createCustomToken(uid);
  const r = await fetch(`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: custom, returnSecureToken: true }),
  });
  const j = await r.json();
  if (!j.idToken) throw new Error("no token: " + JSON.stringify(j));
  return j.idToken;
}

let keyN = 0;
async function order(token, data) {
  const body = {
    contactPhone: "+77000000000", deliveryAddress: "Астана, ул. Тестовая 1",
    idempotencyKey: "v2-key-" + (++keyN), ...data,
  };
  const r = await fetch(FN, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data: body }),
  });
  return { body, res: await r.json() };
}

(async () => {
  const storefront = {
    cutting: [{ id: "c1", name: "Традиционная Мүшелеу", price: 15000, note: "12 жілік" }],
    delivery: [{ id: "d1", city: "Астана", price: 5000 }],
    pickup: true,
  };
  const b = db.batch();
  b.set(db.doc("partners/v2_farm"), { uid: "v2_farm", displayName: "КХ Формат", status: "verified", storefront });
  b.set(db.doc("partners/v2_bare"), { uid: "v2_bare", displayName: "КХ Без тарифов", status: "verified" });
  const lot = (partnerId, over) => ({ partnerId, name: "Туша", status: "open", bookedShares: 0, ...over });
  b.set(db.doc("lots/H"), lot("v2_farm", { totalShares: 2, pricePerKg: 3500, totalWeight: 120, pricePerShare: 210000 }));
  b.set(db.doc("lots/H2"), lot("v2_farm", { totalShares: 2, pricePerKg: 3500, totalWeight: 120, pricePerShare: 210000 }));
  b.set(db.doc("lots/W"), lot("v2_farm", { totalShares: 1, pricePerKg: 3000, totalWeight: 100, pricePerShare: 300000 }));
  b.set(db.doc("lots/B"), lot("v2_bare", { totalShares: 2, pricePerKg: 3000, totalWeight: 100, pricePerShare: 150000 }));
  b.set(db.doc("lots/LEG"), lot("v2_bare", { totalShares: 6, pricePerShare: 50000 }));
  await b.commit();

  const token = await idTokenFor("v2_buyer", "+15550009201");
  const checks = [];
  const lotOf = async (id) => (await db.doc("lots/" + id).get()).data();
  const orderOf = async (res) => (await db.doc("orders/" + res.result.orderId).get()).data();
  const ok = async (label, data, verify) => {
    const { res } = await order(token, data);
    let pass = !!res.result;
    let info = JSON.stringify(res);
    if (pass && verify) {
      const o = await orderOf(res);
      pass = await verify(o, res);
      info = JSON.stringify({ amount: o.amount, pricing: o.pricing, format: o.format, delivery: o.delivery, cutting: o.cutting });
    }
    checks.push([pass, label, pass ? "" : info]);
    return res;
  };
  const fails = async (label, data, status) => {
    const { res } = await order(token, data);
    const pass = !!res.error && res.error.status === status;
    checks.push([pass, label, pass ? "" : JSON.stringify(res)]);
  };

  const first = await ok("half + Мүшелеу + delivery to Астана: 210 000 + 15 000 + 5 000", { lotId: "H", format: "half", cuttingId: "c1", deliveryId: "d1", deliveryDate: new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 10), deliverySlot: "evening" },
    async (o) => o.amount === 230000 && o.pricing.meat === 210000 && o.pricing.cutting === 15000 && o.pricing.delivery === 5000
      && o.estimatedWeightKg === 60 && o.shares === 1 && o.cutting.name === "Традиционная Мүшелеу" && o.delivery.city === "Астана"
      && o.deliverySlot === "evening" && (await lotOf("H")).bookedShares === 1 && (await lotOf("H")).status === "open");

  // Replaying the same key returns the same order and books nothing more.
  {
    const { res } = await order(token, { lotId: "H", format: "half", cuttingId: "c1", deliveryId: "d1", idempotencyKey: "v2-key-1" });
    checks.push([res.result?.orderId === first.result?.orderId && res.result?.replayed === true && (await lotOf("H")).bookedShares === 1,
      "a replay with the same key returns the first order", JSON.stringify(res)]);
  }

  await fails("whole of a carcass with a half already booked", { lotId: "H", format: "whole", deliveryId: "d1" }, "FAILED_PRECONDITION");
  await ok("the second half with pickup needs no address; the carcass sells out",
    { lotId: "H", format: "half", deliveryId: "pickup", deliveryAddress: "" },
    async (o) => o.amount === 210000 && o.delivery.mode === "pickup" && o.deliveryAddress === "" && (await lotOf("H")).status === "fully_booked");
  await fails("a third half of the same carcass", { lotId: "H", format: "half", deliveryId: "pickup" }, "FAILED_PRECONDITION");

  await fails("a half of a carcass sold only whole", { lotId: "W", format: "half", deliveryId: "d1" }, "FAILED_PRECONDITION");
  await ok("whole with Мүшелеу costs the cutting twice: 300 000 + 30 000 + 5 000",
    { lotId: "W", format: "whole", cuttingId: "c1", deliveryId: "d1" },
    async (o) => o.amount === 335000 && o.pricing.cutting === 30000 && o.cutting.pricePerHalf === 15000 && o.estimatedWeightKg === 100);

  await fails("no delivery chosen at a farm that has tariffs", { lotId: "H2", format: "half" }, "INVALID_ARGUMENT");
  await fails("a delivery city the farm does not serve", { lotId: "H2", format: "half", deliveryId: "nowhere" }, "FAILED_PRECONDITION");
  await fails("a cutting the farm does not offer", { lotId: "H2", format: "half", deliveryId: "d1", cuttingId: "c9" }, "FAILED_PRECONDITION");
  await fails("city delivery without an address", { lotId: "H2", format: "half", deliveryId: "d1", deliveryAddress: "" }, "INVALID_ARGUMENT");
  await fails("an unknown format", { lotId: "H2", format: "quarter", deliveryId: "d1" }, "INVALID_ARGUMENT");
  await fails("an unknown delivery time", { lotId: "H2", format: "half", deliveryId: "d1", deliverySlot: "night" }, "INVALID_ARGUMENT");
  await fails("a delivery date in the past", { lotId: "H2", format: "half", deliveryId: "d1", deliveryDate: "2020-01-01" }, "INVALID_ARGUMENT");
  checks.push([(await lotOf("H2")).bookedShares === 0, "none of the refusals booked anything", ""]);

  await ok("a farm without tariffs: delivery by agreement, to an address", { lotId: "B", format: "half" },
    async (o) => o.amount === 150000 && o.delivery.mode === "agree" && o.deliveryAddress.length > 0);
  await fails("pickup at a farm that does not offer it", { lotId: "B", format: "half", deliveryId: "pickup" }, "FAILED_PRECONDITION");

  await ok("the older share-count order still works", { lotId: "LEG", shares: 2 },
    async (o) => o.amount === 100000 && o.format === null && o.shares === 2 && (await lotOf("LEG")).bookedShares === 2);

  for (const [pass, label, info] of checks) console.log(`  ${pass ? "ok  " : "FAIL"}  ${label}${pass ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\norders with formats: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
