// createOrder must refuse lots of farms the platform has not checked - and a refused order must
// leave nothing booked and no purchase mirror behind.
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

async function order(token, lotId, key) {
  const r = await fetch(FN, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data: { lotId, shares: 1, deliveryAddress: "Астана, ул. Тестовая 1", contactPhone: "+77000000000", idempotencyKey: key } }),
  });
  return r.json();
}

(async () => {
  const b = db.batch();
  b.set(db.doc("partners/g_ok"), { uid: "g_ok", displayName: "Проверенное", status: "verified" });
  b.set(db.doc("partners/g_active"), { uid: "g_active", displayName: "Активное", status: "active" });
  b.set(db.doc("partners/g_pending"), { uid: "g_pending", displayName: "На проверке", status: "pending_review" });
  b.set(db.doc("partners/g_rejected"), { uid: "g_rejected", displayName: "Отклонённое", status: "rejected" });
  const lot = (partnerId) => ({ partnerId, name: "Лот " + partnerId, status: "open", totalShares: 6, bookedShares: 0, pricePerShare: 50000 });
  b.set(db.doc("lots/L_ok"), lot("g_ok"));
  b.set(db.doc("lots/L_active"), lot("g_active"));
  b.set(db.doc("lots/L_pending"), lot("g_pending"));
  b.set(db.doc("lots/L_rejected"), lot("g_rejected"));
  b.set(db.doc("lots/L_nofarm"), lot("g_does_not_exist"));
  const orphan = lot("x"); delete orphan.partnerId;
  b.set(db.doc("lots/L_orphan"), orphan);
  await b.commit();

  const token = await idTokenFor("gate_buyer", "+15550009999");
  const cases = [
    ["L_ok", true], ["L_active", true],
    ["L_pending", false], ["L_rejected", false], ["L_nofarm", false], ["L_orphan", false],
  ];
  let failed = 0;
  for (const [lotId, shouldPass] of cases) {
    const res = await order(token, lotId, "gate-key-" + lotId);
    const passed = !!res.result?.orderId;
    const booked = (await db.doc("lots/" + lotId).get()).data().bookedShares;
    const ok = passed === shouldPass && booked === (shouldPass ? 1 : 0);
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"}  ${lotId.padEnd(11)} expected ${shouldPass ? "order" : "refusal"}, got ${passed ? "order " + res.result.orderId : (res.error?.status + ": " + res.error?.message)}; bookedShares=${booked}`);
  }
  // Refused attempts must leave nothing behind for the buyer either.
  const purchases = await db.collection("clients/gate_buyer/purchases").get();
  const ids = purchases.docs.map((d) => d.id).sort();
  const mirrorOk = JSON.stringify(ids) === JSON.stringify(["L_active", "L_ok"]);
  if (!mirrorOk) failed++;
  console.log(`${mirrorOk ? "PASS" : "FAIL"}  purchase mirrors only for accepted orders: ${ids.join(", ")}`);
  console.log(failed ? `${failed} FAILED` : "all passed");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
