// setHubLocation keeps the exact point private and publishes only a ~5 km cell centre;
// reviewPartner keeps the moderator's reason off the public profile.
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
const AUTH = `http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1`;
const fn = (name) => `http://127.0.0.1:5001/demo-et/europe-west3/${name}`;

async function tokenFor(uid, phone, claims) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  if (claims) await auth.setCustomUserClaims(uid, claims);
  const r = await fetch(`${AUTH}/accounts:signInWithCustomToken?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: await auth.createCustomToken(uid), returnSecureToken: true }),
  });
  return (await r.json()).idToken;
}

async function anonymousToken() {
  const r = await fetch(`${AUTH}/accounts:signUp?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ returnSecureToken: true }),
  });
  return (await r.json()).idToken;
}

async function call(name, token, data) {
  const r = await fetch(fn(name), {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: "Bearer " + token } : {}) },
    body: JSON.stringify({ data }),
  });
  return r.json();
}

function km(a, b) {
  const R = 6371, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

const results = [];
function check(label, ok, detail = "") {
  results.push(ok);
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  (" + detail + ")" : ""}`);
}

(async () => {
  await db.doc("partners/hub1").set({ uid: "hub1", displayName: "Хаб", status: "pending_review", city: "Караганда" });
  await db.doc("partners/hub2").set({ uid: "hub2", displayName: "Хаб 2", status: "verified", reviewNote: "старая причина", reviewedBy: "someone" });
  await db.doc("staff/mod1").set({ uid: "mod1", role: "admin" });

  const farmer = await tokenFor("hub1", "+15550007001");
  const exact = { lat: 49.80471, lng: 73.10938 };

  // --- set a point ---------------------------------------------------------------------------
  const set1 = await call("setHubLocation", farmer, exact);
  const shown = set1.result?.publicLocation;
  check("farm sets its point", !!shown, JSON.stringify(set1.error || shown));
  const dist = shown ? km(exact, shown) : Infinity;
  check("public point is within ~3.5 km of the exact one", dist <= 3.6, dist.toFixed(2) + " km");
  check("public point is NOT the exact point", shown && (shown.lat !== exact.lat || shown.lng !== exact.lng));
  check("public point says its precision", shown?.precisionKm === 5);

  const priv = (await db.doc("partners/hub1/private/location").get()).data();
  check("exact point is stored privately", priv?.lat === exact.lat && priv?.lng === exact.lng);
  const pub = (await db.doc("partners/hub1").get()).data();
  check("profile carries only the public point", pub.publicLocation?.lat === shown?.lat && pub.publicLocation?.lng === shown?.lng
    && !("lat" in pub) && !("lng" in pub));

  const nearby = await call("setHubLocation", farmer, { lat: exact.lat + 0.004, lng: exact.lng + 0.004 });
  const same = nearby.result?.publicLocation;
  check("a point 500 m away in the same cell publishes the same point (no averaging leak)",
    same?.lat === shown?.lat && same?.lng === shown?.lng, JSON.stringify(same));

  // --- refusals ------------------------------------------------------------------------------
  const zero = await call("setHubLocation", farmer, { lat: 0, lng: 0 });
  check("(0, 0) is refused", zero.error?.status === "INVALID_ARGUMENT", zero.error?.message);
  const moscow = await call("setHubLocation", farmer, { lat: 55.75, lng: 37.62 });
  check("a point outside Kazakhstan is refused", moscow.error?.status === "INVALID_ARGUMENT");
  const junk = await call("setHubLocation", farmer, { lat: "abc", lng: null });
  check("non-numbers are refused", junk.error?.status === "INVALID_ARGUMENT");

  const notFarm = await tokenFor("buyer9", "+15550007002");
  const nf = await call("setHubLocation", notFarm, exact);
  check("an account without a farm is refused", nf.error?.status === "FAILED_PRECONDITION", nf.error?.message);
  const noFarmDoc = await db.doc("partners/buyer9").get();
  check("...and no farm document appears for it", !noFarmDoc.exists);

  const anon = await call("setHubLocation", await anonymousToken(), exact);
  check("an anonymous session is refused", anon.error?.status === "PERMISSION_DENIED", anon.error?.message);
  const nobody = await call("setHubLocation", null, exact);
  check("no session at all is refused", nobody.error?.status === "UNAUTHENTICATED");

  // --- clear -------------------------------------------------------------------------------
  const cleared = await call("setHubLocation", farmer, { clear: true });
  const afterClear = (await db.doc("partners/hub1").get()).data();
  const privGone = !(await db.doc("partners/hub1/private/location").get()).exists;
  check("clearing removes both points", cleared.result?.publicLocation === null && afterClear.publicLocation === null && privGone);

  // --- reviewPartner keeps the reason private --------------------------------------------------
  const mod = await tokenFor("mod1", "+15550007003", { role: "admin" });
  const rej = await call("reviewPartner", mod, { partnerId: "hub2", decision: "reject", note: "Справки просрочены" });
  check("moderator rejects a farm", rej.result?.status === "rejected", JSON.stringify(rej.error || rej.result));
  const hub2 = (await db.doc("partners/hub2").get()).data();
  check("public profile holds no reason and no moderator id", !("reviewNote" in hub2) && !("reviewedBy" in hub2) && !!hub2.reviewedAt);
  const review = (await db.doc("partners/hub2/private/review").get()).data();
  check("reason is stored privately", review?.decision === "reject" && review?.note === "Справки просрочены" && review?.decidedBy === "mod1");
  const appr = await call("reviewPartner", mod, { partnerId: "hub2", decision: "approve" });
  const review2 = (await db.doc("partners/hub2/private/review").get()).data();
  check("re-approval replaces the private verdict", appr.result?.status === "verified" && review2?.decision === "approve" && review2?.note === null);

  const failed = results.filter((r) => !r).length;
  console.log(failed ? `${failed} FAILED` : `all ${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
