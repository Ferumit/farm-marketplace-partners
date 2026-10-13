// reviewDocument on a farm's own certificates: the public `certified` badge follows the decisions -
// on only when both СЭС and ветконтроль are approved, off again when one of them is rejected - and
// only a moderator can decide.
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
const FN = "http://127.0.0.1:5001/demo-et/europe-west3/reviewDocument";

async function idTokenFor(uid, phone, claims = {}) {
  await auth.createUser({ uid, phoneNumber: phone }).catch(() => {});
  const custom = await auth.createCustomToken(uid, claims);
  const r = await fetch(`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: custom, returnSecureToken: true }),
  });
  const j = await r.json();
  if (!j.idToken) throw new Error("no token: " + JSON.stringify(j));
  return j.idToken;
}

async function review(token, data) {
  const r = await fetch(FN, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer " + token },
    body: JSON.stringify({ data }),
  });
  return r.json();
}

(async () => {
  const b = db.batch();
  b.set(db.doc("staff/fd_admin"), { uid: "fd_admin", role: "admin" });
  b.set(db.doc("staff/fd_support"), { uid: "fd_support", role: "support" });
  b.set(db.doc("partners/fd_farm"), { uid: "fd_farm", displayName: "КХ Сертификат", status: "verified" });
  const cert = (kind) => ({ kind, status: "pending", partnerId: "fd_farm", reviewedBy: null, uploadedAt: new Date() });
  b.set(db.doc("partners/fd_farm/documents/ses"), cert("ses"));
  b.set(db.doc("partners/fd_farm/documents/vet"), cert("vet_control"));
  await b.commit();

  const admin = await idTokenFor("fd_admin", "+15550009101", { role: "admin" });
  const support = await idTokenFor("fd_support", "+15550009102", { role: "support" });

  const checks = [];
  const certified = async () => (await db.doc("partners/fd_farm").get()).data().certified;
  const step = async (label, token, data, expectStatus, expectCertified) => {
    const res = await review(token, data);
    let ok;
    if (expectStatus) ok = !!res.error && res.error.status === expectStatus;
    else ok = !!res.result && (await certified()) === expectCertified;
    checks.push([ok, label, ok ? "" : JSON.stringify(res) + " certified=" + (await certified())]);
  };

  await step("support cannot decide a farm certificate", support,
    { partnerId: "fd_farm", docId: "ses", decision: "approve" }, "PERMISSION_DENIED");
  await step("СЭС approved alone: not certified yet", admin,
    { partnerId: "fd_farm", docId: "ses", decision: "approve" }, null, false);
  await step("ветконтроль approved too: certified", admin,
    { partnerId: "fd_farm", docId: "vet", decision: "approve" }, null, true);
  await step("СЭС taken back: certified is off again", admin,
    { partnerId: "fd_farm", docId: "ses", decision: "reject", note: "Срок действия истёк" }, null, false);
  await step("a document that does not exist", admin,
    { partnerId: "fd_farm", docId: "nope", decision: "approve" }, "NOT_FOUND");
  await step("neither an animal nor a farm named", admin,
    { docId: "ses", decision: "approve" }, "INVALID_ARGUMENT");

  const audited = (await db.collection("adminActions").where("targetId", ">=", "farm:fd_farm/").where("targetId", "<", "farm:fd_farm0").get()).size;
  checks.push([audited === 3, "each decision left an audit record", "got " + audited]);

  for (const [ok, label, info] of checks) console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}${ok ? "" : "  " + info}`);
  const failed = checks.filter((c) => !c[0]).length;
  console.log(`\nfarm documents: ${checks.length - failed}/${checks.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
